#!/bin/bash
# Shared ntfy publishing for Backup Suite. Source after common.sh and
# load_global_config.
#
# ntfy turns any body larger than 4096 bytes into a file attachment with no
# readable message. Every notification therefore carries a bounded,
# human-readable description as the message and, when available, the full
# detail record as a separate attachment.

ntfy_ascii_text() {
    # Keep tabs, newlines, and printable ASCII so byte and character counts match.
    printf '%s' "$1" | LC_ALL=C tr -c '\11\12\40-\176' '?' | LC_ALL=C tr '\11' ' '
}

ntfy_header_value() {
    local value="$1"
    local max_length="${2:-200}"

    value=$(printf '%s' "$value" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C tr -cd '\40-\176')
    printf '%s' "${value:0:max_length}"
}

ntfy_bound_text() {
    local text="$1"
    local max_bytes="$2"
    local marker=$'\n[... shortened; full details are in the attachment or local record]'

    if [ "${#text}" -le "$max_bytes" ]; then
        printf '%s' "$text"
        return 0
    fi

    text="${text:0:$((max_bytes - ${#marker}))}"
    text="${text%$'\n'*}"
    printf '%s%s' "$text" "$marker"
}

ntfy_publish() {
    # Usage: ntfy_publish <title> <priority> <tags> <message> [attachment-file] [attachment-name]
    local title="$1"
    local priority="$2"
    local tags="$3"
    local message="$4"
    local attachment_file="${5:-}"
    local attachment_name="${6:-}"
    local topic_url
    local max_bytes="${NOTIFY_NTFY_MESSAGE_MAX_BYTES:-3500}"
    local header_message
    local curl_common=()
    local token

    if ! is_enabled_value "${NOTIFY_FAILURES_ENABLED:-0}"; then
        echo "ntfy notifications are disabled; not sending: $title"
        return 0
    fi

    topic_url=$(trim "${NOTIFY_NTFY_TOPIC_URL:-}")
    if [ -z "$topic_url" ]; then
        echo "NOTIFY_NTFY_TOPIC_URL is empty; cannot send: $title" >&2
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is not installed; cannot send: $title" >&2
        return 1
    fi

    [[ "$max_bytes" =~ ^[0-9]+$ ]] && [ "$max_bytes" -ge 512 ] && [ "$max_bytes" -le 4000 ] || max_bytes=3500

    message=$(ntfy_ascii_text "$message")
    message=$(ntfy_bound_text "$message" "$max_bytes")
    title=$(ntfy_header_value "$title" 200)
    priority=$(ntfy_header_value "${priority:-default}" 20)
    tags=$(ntfy_header_value "$tags" 100)

    curl_common=(-fsS --max-time 30 --retry 2 --retry-delay 3 -o /dev/null
        -H "Title: $title"
        -H "Priority: $priority"
        -H "Tags: $tags")
    token=$(trim "${NOTIFY_NTFY_TOKEN:-}")
    if [ -n "$token" ]; then
        curl_common+=(-H "Authorization: Bearer $token")
    fi

    if [ -n "$attachment_file" ] && [ -f "$attachment_file" ] && is_enabled_value "${NOTIFY_NTFY_ATTACH_DETAILS:-1}"; then
        [ -n "$attachment_name" ] || attachment_name=$(basename "$attachment_file")
        attachment_name=$(ntfy_header_value "$attachment_name" 120)
        # ntfy converts a literal \n in the Message header into a line break.
        header_message=$(printf '%s' "$message" | awk 'BEGIN { ORS = "" } NR > 1 { print "\\n" } { print }')
        if curl "${curl_common[@]}" \
            -X PUT \
            -T "$attachment_file" \
            -H "Filename: $attachment_name" \
            -H "Message: $header_message" \
            "$topic_url"; then
            echo "ntfy notification sent with attachment '$attachment_name': $title"
            return 0
        fi
        echo "ntfy attachment upload failed; resending as a plain message: $title" >&2
    fi

    if curl "${curl_common[@]}" --data-binary "$message" "$topic_url"; then
        echo "ntfy notification sent: $title"
        return 0
    fi

    echo "ntfy notification could not be delivered: $title" >&2
    return 1
}

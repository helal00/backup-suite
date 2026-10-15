#!/bin/bash
# Notifications for Backup Suite. Source after common.sh and load_global_config.
#
# One generic message (title, priority, description, optional detail file) goes to
# every enabled channel: notify_publish -> channel_<name>_deliver. ntfy is the first
# channel; others (Telegram, WhatsApp, email, SMS) are added as channel_<name>_*
# functions and listed in NOTIFY_CHANNELS. Every message is also recorded as an
# event, with what each channel did with it.
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

BACKUP_EVENTS_KEEP_LINES=1000

ntfy_priority_severity() {
    case "$1" in
        urgent|max|5|high|4) printf 'error' ;;
        low|2|min|1) printf 'info' ;;
        *) printf 'warning' ;;
    esac
}

NOTIFY_CHANNELS="ntfy"

record_backup_event() {
    # Usage: record_backup_event <info|warning|error> <category> <title> <message> [unit] [delivery]
    # Appends one JSON line to STATE_DIR/events.jsonl for the GUI and Tunnel
    # Manager. delivery is what each channel did, "ntfy=sent,telegram=failed"
    # (sent, failed, or off when the channel is disabled), "held" (already
    # reported in this episode: sent nowhere), or empty (shown in the GUI only).
    # Never fails the caller.
    local severity="$1"
    local category="$2"
    local title="$3"
    local message="$4"
    local unit="${5:-}"
    local ntfy="${6:-}"
    local events_file
    local sequence_file
    local lock_file

    [ -n "${STATE_DIR:-}" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    events_file=$(join_path "$STATE_DIR" "events.jsonl")
    sequence_file=$(join_path "$STATE_DIR" "events.seq")
    lock_file=$(join_path "$STATE_DIR" "events.lock")
    case "$severity" in
        info|warning|error) ;;
        *) severity="warning" ;;
    esac
    local delivery_json="{}"
    local held="false"
    local pair channel result
    if [ "$ntfy" = "held" ]; then
        held="true"
    elif [ -n "$ntfy" ]; then
        delivery_json=""
        for pair in ${ntfy//,/ }; do
            channel="${pair%%=*}"
            result="${pair#*=}"
            [[ "$channel" =~ ^[a-z]+$ ]] || continue
            case "$result" in sent|failed|off) ;; *) continue ;; esac
            delivery_json="${delivery_json:+$delivery_json,}\"$channel\":\"$result\""
        done
        delivery_json="{${delivery_json}}"
    fi
    message="${message:0:4000}"
    (
        flock -w 5 9 || exit 0
        sequence=$(cat "$sequence_file" 2>/dev/null || true)
        [[ "$sequence" =~ ^[0-9]+$ ]] || sequence=0
        sequence=$((sequence + 1))
        printf '%s\n' "$sequence" > "$sequence_file"
        printf '{"seq":%s,"id":"evt-%s-%s","created_at":"%s","severity":"%s","category":"%s","title":"%s","message":"%s","unit":"%s","delivery":%s,"held":%s,"delivery_note":"%s"}\n' \
            "$sequence" "$sequence" "$(date -u '+%s')" "$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')" "$severity" \
            "$(json_escape "$category")" "$(json_escape "$title")" "$(json_escape "$message")" "$(json_escape "$unit")" \
            "$delivery_json" "$held" "$(json_escape "${NOTIFY_DELIVERY_NOTE:-}")" >> "$events_file"
        if [ "$(wc -l < "$events_file")" -gt $((BACKUP_EVENTS_KEEP_LINES + 100)) ]; then
            trimmed_file=$(mktemp)
            tail -n "$BACKUP_EVENTS_KEEP_LINES" "$events_file" > "$trimmed_file" && cat "$trimmed_file" > "$events_file"
            rm -f "$trimmed_file"
        fi
    ) 9>>"$lock_file" 2>/dev/null || true
    return 0
}

notify_publish() {
    # Usage: notify_publish <title> <priority> <tags> <message> [attachment-file] [attachment-name] [event-category]
    # Sends one message to every enabled channel and records it as an event with
    # each channel's result. Returns non-zero when an enabled channel failed.
    local channel
    local status
    local delivery=""
    local failed=0
    local notes=""

    for channel in $NOTIFY_CHANNELS; do
        NOTIFY_CHANNEL_NOTE=""
        status=0
        "channel_${channel}_deliver" "$@" || status=$?
        case "$status" in
            0) delivery="${delivery:+$delivery,}$channel=sent" ;;
            3) delivery="${delivery:+$delivery,}$channel=off" ;;
            *)
                delivery="${delivery:+$delivery,}$channel=failed"
                failed=1
                ;;
        esac
        [ -n "$NOTIFY_CHANNEL_NOTE" ] && notes="${notes:+$notes; }$channel: $NOTIFY_CHANNEL_NOTE"
    done
    NOTIFY_DELIVERY_NOTE="$notes" record_backup_event "$(ntfy_priority_severity "$2")" "${7:-alert}" "$1" "$4" "${BACKUP_EVENT_UNIT:-}" "$delivery"
    return "$failed"
}

# Older name, kept for scripts that still call it.
ntfy_publish() {
    notify_publish "$@"
}

channel_ntfy_deliver() {
    # The ntfy channel: 0 sent, 1 not delivered (NOTIFY_CHANNEL_NOTE says why),
    # 3 the channel is off (NOTIFY_FAILURES_ENABLED is its switch).
    local title="$1"
    local priority="$2"
    local tags="$3"
    local message="$4"
    local attachment_file="${5:-}"
    local attachment_name="${6:-}"
    local event_category="${7:-alert}"
    local topic_url
    local max_bytes="${NOTIFY_NTFY_MESSAGE_MAX_BYTES:-3500}"
    local header_message
    local curl_common=()
    local token

    if ! is_enabled_value "${NOTIFY_FAILURES_ENABLED:-0}"; then
        echo "ntfy notifications are disabled; not sending: $title"
        return 3
    fi

    topic_url=$(trim "${NOTIFY_NTFY_TOPIC_URL:-}")
    if [ -z "$topic_url" ]; then
        echo "NOTIFY_NTFY_TOPIC_URL is empty; cannot send: $title" >&2
        NOTIFY_CHANNEL_NOTE="no topic URL is set"
        return 1
    fi
    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is not installed; cannot send: $title" >&2
        NOTIFY_CHANNEL_NOTE="curl is not installed"
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
    NOTIFY_CHANNEL_NOTE="the ntfy server did not accept it (network, topic or token)"
    return 1
}

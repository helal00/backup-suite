#!/bin/bash

set -euo pipefail

: "${FAKE_CURL_LOG:?FAKE_CURL_LOG is required}"
printf 'curl invoked with %s arguments\n' "$#" >> "$FAKE_CURL_LOG"

is_put=0
previous=""
for argument in "$@"; do
    printf 'arg: %s\n' "$argument" >> "$FAKE_CURL_LOG"
    if [ "$previous" = "-X" ] && [ "$argument" = "PUT" ]; then
        is_put=1
    fi
    if [ "$previous" = "-T" ] && [ -f "$argument" ]; then
        # Keep attachment bodies so tests can read what the user would open.
        { printf 'attachment-begin\n'; cat "$argument"; printf 'attachment-end\n'; } >> "${FAKE_CURL_LOG}.attachments"
    fi
    previous="$argument"
done
printf 'end of request\n' >> "$FAKE_CURL_LOG"

if [ "$is_put" -eq 1 ] && [ "${FAKE_CURL_FAIL_PUT:-0}" = "1" ]; then
    echo "curl: (22) The requested URL returned error: 400" >&2
    exit 22
fi

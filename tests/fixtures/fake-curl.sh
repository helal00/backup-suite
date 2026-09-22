#!/bin/bash

set -euo pipefail

: "${FAKE_CURL_LOG:?FAKE_CURL_LOG is required}"
printf 'curl invoked with %s arguments\n' "$#" >> "$FAKE_CURL_LOG"

#!/usr/bin/env bash
# Reports uid 0 so the GUI tests can be run as if under sudo without being root.
case "${1:-}" in
    -u) echo 0 ;;
    -un) echo root ;;
    *) exec /usr/bin/id "$@" ;;
esac

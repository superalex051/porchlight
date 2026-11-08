#!/usr/bin/env bash
# Follows the plain text logs. With --os, follows the app's system log instead. Read only.
set -euo pipefail

LOGS="$HOME/Library/Logs/PorchLight"

case "${1:-}" in
    "") exec tail -n 50 -F "$LOGS/session.log" "$LOGS/guardian.log" ;;
    --os) exec log stream --level debug --predicate 'subsystem == "com.alexluncan.PorchLight"' ;;
    *) echo "logs.sh: unknown argument: $1. It takes --os." >&2; exit 1 ;;
esac

#!/usr/bin/env bash
# Opens the installed app, with --safe passed through. It only takes effect if the app isn't already
# running. Agents never run this: launching the app can change display state.
set -euo pipefail

if [ -n "${AD_NO_INSTALL:-}" ]; then
    echo "run.sh: refusing, because AD_NO_INSTALL is set." >&2
    exit 1
fi

INSTALLED="/Applications/PorchLight.app"
[ -d "$INSTALLED" ] || { echo "run.sh: $INSTALLED is missing. Run Scripts/install.sh." >&2; exit 1; }

case "${1:-}" in
    "") exec open -g -a "$INSTALLED" ;;
    --safe) exec open -g -a "$INSTALLED" --args --safe ;;
    *) echo "run.sh: unknown argument: $1. It takes --safe." >&2; exit 1 ;;
esac

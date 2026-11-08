#!/usr/bin/env bash
# Scenario 9: every command in scenario 1 finishes within the limit the CLI holds it to: 60 seconds
# for a session operation, which is what both scripts run. Runs scenario 1 itself, collects each
# command's time, and prints the slowest. A command near its limit fails here, past half of it, so a
# slow end shows up before a script times out.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "09-timing"

export E2E_TIMINGS="$WORK/timings-01"
: >"$E2E_TIMINGS"
"$E2E_REPO/Scripts/e2e/01-parsec-scripts.sh" >"$WORK/scenario-01.out" 2>&1
CODE=$?
cat "$WORK/scenario-01.out" >>"$WORK/transcript"
[ "$CODE" = 0 ] || fail "scenario 1 failed, so its times mean nothing: $(tail -1 "$WORK/scenario-01.out")"
unset E2E_TIMINGS

count="$(grep -c . "$WORK/timings-01")"
[ "$count" -gt 0 ] || fail "scenario 1 recorded no times"
while read -r secs limit label; do
    less_than "$secs" "$limit" || fail "$label took $secs s, past its $limit s limit"
    less_than "$secs" "$(perl -e 'print $ARGV[0] / 2' "$limit")" || fail "$label took $secs s, more than half its $limit s limit"
done <"$WORK/timings-01"

echo "  slowest five of $count:"
sort -rn "$WORK/timings-01" | head -5 | while read -r secs limit label; do
    echo "    $secs s of $limit s: $label"
done
read -r secs limit label <<<"$(sort -rn "$WORK/timings-01" | head -1)"
e2e_pass "$count commands within their limits, none past half; slowest: $label at $secs s of $limit s"

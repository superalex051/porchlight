#!/usr/bin/env bash
# Scenario 4: the calling app dies. A session tied by -ownerpid to a short `sleep`, with a dry-run
# `porchlight-guardian` watching the same state directory. When the sleep exits, the guardian asks the
# host to end, the session ends, and the plan shows every monitor back. A dead PID at start is refused.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "04-dead-owner"

start_host
start_guardian

# A PID that's already gone is refused before anything changes.
sleep 0 &
GONE=$!
wait "$GONE"
cli session start -client=caller "-ownerpid=$GONE"
expect_code 1 "start with a dead owner"
expect_err "Failed. owner process $GONE is not running" "start with a dead owner"
[ ! -e "$(ledger)" ] || fail "a refused start left a ledger"

sleep 4 &
OWNER=$!
track "$OWNER"
cli session start -client=caller -lookslike=1311x603 "-ownerpid=$OWNER"
expect_ok "start with a live owner"
LINE="$OUT"
OFF="$(field off "$LINE")"
[ -n "$OFF" ] || fail "the session turned nothing off"
[ "$(ledger_value '.owners | map(.pid) | join(",")')" = "$OWNER" ] || fail "the ledger's owners are $(ledger_value '.owners')"
note "session up with owner $OWNER, off=$OFF"

# The guardian pings it as healthy while the owner lives.
wait "$OWNER"
DIED_AT="$(now)"
note "owner $OWNER exited"

session_idle() {
    [ "$("$CLI" --no-launch session status 2>/dev/null)" = "state=idle" ]
}
wait_for 30 "the session ending after its owner died" session_idle
ENDED_IN="$(elapsed "$DIED_AT" "$(now)")"
[ ! -e "$(ledger)" ] || fail "the session ended but its ledger is still there: $(ledger_value .state)"

# Who ended it, and why.
grep -q "owner $OWNER died, asking the app to end the session" "$WORK/guardian.log" ||
    fail "the guardian never said the owner died"
wait_for 5 "the guardian logging the app's answer" grep -q "the app accepted the request to end" "$WORK/guardian.log"
grep -q "Ending the session: owner-died" "$AD_STATE_DIR/session.log" || fail "the host didn't log an owner-died end"
if grep -qE "relaunching|restoring the monitors|SIGKILL" "$WORK/guardian.log"; then
    fail "the guardian went past asking: $(grep -E 'relaunching|restoring|SIGKILL' "$WORK/guardian.log" | head -3)"
fi

read_plan
check_sessions "$PLAN" 1 "$OFF"

stop_guardian
stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
e2e_pass "a dead PID at start refused; owner $OWNER exited, the guardian asked the host to end with owner-died, the session ended ${ENDED_IN} s later, the ledger is gone and the plan brings back $OFF after the screen was main"

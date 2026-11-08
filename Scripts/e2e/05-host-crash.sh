#!/usr/bin/env bash
# Scenario 5: `kill -9` of the host mid-session.
#
# Part A, with a dry-run `porchlight-guardian` watching. It decides to relaunch, which a dry run can't
# do: `open` passes no environment, so it would start the real app on the real ledger. It refuses and
# logs that. With no app back in 10 seconds it restores through a dry-run `porchlight-guardian restore`
# child, then marks the ledger `rescued`. Asserted from its log, the child's plan in that log, and the
# ledger. The relaunch of a real app can't be tested here: it needs the installed app, and it's on the
# attended list.
#
# Part B, with no guardian: `porchlight-guardian restore` by hand, the way `rescue` runs it with no
# app. A dry run writes no ledger, so the ledger stays as the crash left it, and the plan is the
# evidence.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "05-host-crash"

DRY_STEPS='^dry run: (enable|disable|commit|addVirtual|removeVirtual|setVirtualMode|gone) '

# check_restore_plan <log file> <context>: the dry-run restore started from the monitors off, brought
# each back, turned none off, and reported all back and verified.
check_restore_plan() {
    local file="$1" context="$2" plan id records
    records="$(tr ',' '\n' <<<"$OFF" | grep -c .)"
    grep -qx "dry run: the copy starts with the session's $records monitors off, as after a crash" "$file" ||
        fail "$context: the copy didn't start with the session's monitors off"
    grep -qE "^restore report: $records back, 0 missing, 0 still dark, [0-9]+ attempts, verified true\$" "$file" ||
        fail "$context: the report isn't every record back and verified: $(grep 'restore report' "$file")"
    plan="$(grep -E "$DRY_STEPS" "$file" | sed 's/^dry run: //')"
    check_plan_words "$plan"
    for id in ${OFF//,/ }; do
        grep -qx "enable $id" <<<"$plan" || fail "$context: the plan never brings back display $id: [$plan]"
    done
    if grep -qE '^disable ' <<<"$plan"; then fail "$context: the plan turns a monitor off: [$plan]"; fi
    RESTORE_PLAN="$(tr '\n' ';' <<<"$plan")"
}

# --- Part A: the guardian.
start_host
start_guardian

cli session start -client=parsec "-ownerpid=$$"
expect_ok "session start"
OFF="$(field off "$OUT")"
[ -n "$OFF" ] || fail "the session turned nothing off"
HOST_REF="$(ledger_value .app.pid)"
[ "$HOST_REF" = "$HOST_PID" ] || fail "the ledger's app is $HOST_REF, the host is $HOST_PID"
[ "$(ledger_value '.physical | map(.id) | sort | map(tostring) | join(",")')" = "$OFF" ] ||
    fail "the ledger's records aren't the displays the session turned off"

# Let the guardian see it healthy first, so the crash is a change it notices.
sleep 2.5
crash_host
CRASHED_AT="$(now)"
[ "$(ledger_value .state)" = active ] || fail "after the crash the ledger is $(ledger_value .state)"
note "host $HOST_REF killed with SIGKILL mid-session"

rescued() {
    [ "$(ledger_value .state)" = rescued ]
}
# The 10 second relaunch window, then a restore that waits for the copy's displays to settle.
wait_for 60 "the guardian marking the ledger rescued" rescued
RESCUED_IN="$(elapsed "$CRASHED_AT" "$(now)")"
[ "$(ledger_value .app.pid)" = "$HOST_REF" ] || fail "the rescued ledger names another app"

log_line() {
    grep -n -m1 -F "$1" "$WORK/guardian.log" | cut -d: -f1
}
relaunch="$(log_line "the app is not running, relaunching it, 1 of 2")"
refused="$(log_line "a test setup doesn't start the real app")"
restoring="$(log_line "restoring the monitors, attempt 1")"
child="$(log_line "dry run: restore starting")"
succeeded="$(log_line "restore succeeded, attempt 1")"
for step in relaunch refused restoring child succeeded; do
    [ -n "${!step}" ] || fail "the guardian log has no $step line"
done
[ "$relaunch" -lt "$refused" ] && [ "$refused" -lt "$restoring" ] && [ "$restoring" -lt "$child" ] &&
    [ "$child" -lt "$succeeded" ] || fail "the guardian's steps are out of order"
if grep -q "relaunching it, 2 of 2" "$WORK/guardian.log"; then
    fail "the guardian relaunched twice, the first window should have led to a restore"
fi
check_restore_plan "$WORK/guardian.log" "the guardian's restore"
A_PLAN="$RESTORE_PLAN"
note "part A: rescued ${RESCUED_IN} s after the crash; the child's plan: $A_PLAN"
stop_guardian

# --- Part B: by hand, no guardian. A new host finds the rescued ledger and clears it.
start_host
[ ! -e "$(ledger)" ] || fail "a new host left the rescued ledger in place: $(ledger_value .state)"
cli session start -client=parsec "-ownerpid=$$"
expect_ok "the second session's start"
[ "$(field off "$OUT")" = "$OFF" ] || fail "the second session turned off other displays: $OUT"
crash_host
cp "$(ledger)" "$WORK/ledger-at-crash.json"

e2e_guard
started="$(now)"
"$GUARDIAN" restore >"$WORK/restore.out" 2>"$WORK/restore.err"
CODE=$?
SECS="$(elapsed "$started" "$(now)")"
[ "$CODE" = 0 ] || fail "porchlight-guardian restore exited $CODE: $(cat "$WORK/restore.err")"
[ ! -s "$WORK/restore.out" ] || fail "porchlight-guardian restore wrote to stdout: $(cat "$WORK/restore.out")"
grep -qx "dry run: restore starting" "$WORK/restore.err" || fail "porchlight-guardian restore didn't say it's a dry run"
grep -qx "restore succeeded" "$WORK/restore.err" || fail "porchlight-guardian restore didn't succeed: $(cat "$WORK/restore.err")"
check_restore_plan "$WORK/restore.err" "the by-hand restore"
cmp -s "$(ledger)" "$WORK/ledger-at-crash.json" || fail "a dry-run restore changed the ledger"
note "part B: porchlight-guardian restore took $SECS s; its plan: $RESTORE_PLAN"

e2e_pass "kill -9 mid-session: the guardian decided to relaunch, refused to start the real app in a dry run, restored after the 10 s window and marked the ledger rescued ${RESCUED_IN} s after the crash; that restore and a by-hand porchlight-guardian restore each started from the monitors off and brought back $OFF; a dry run left the ledger as it was"

#!/usr/bin/env bash
# Scenario 1: the new parsec-mode and desk-mode, run as scripts against a dry-run host.
# Copies of Scripts/parsec/parsec-mode and desk-mode, with only the AD= line changed to the built CLI.
# Two normal cycles, then out of order: desk-mode with no session, parsec-mode twice (the second keeps
# a size picked in between), and both scripts while another client holds the session.
# Every command's time goes to E2E_TIMINGS if that's set, for 09-timing.sh.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "01-parsec-scripts"

# The copies, and proof that only the AD= line differs.
mkdir -p "$WORK/scripts"
for script in parsec-mode desk-mode; do
    sed "s|^AD=.*\$|AD=\"$CLI\"|" "Scripts/parsec/$script" >"$WORK/scripts/$script"
    chmod +x "$WORK/scripts/$script"
    changed="$(diff "Scripts/parsec/$script" "$WORK/scripts/$script" | grep '^[<>]' || true)"
    [ "$(grep -c . <<<"$changed")" = 2 ] || fail "the copy of $script differs in more than one line: $changed"
    grep -q '^> AD="' <<<"$changed" || fail "the copy of $script changed something other than AD="
done
PARSEC_MODE="$WORK/scripts/parsec-mode"
DESK_MODE="$WORK/scripts/desk-mode"

start_host
BEFORE="$(arrangement)"
[ -n "$BEFORE" ] || fail "the simulated copy shows no display that's on"
# What the script itself will find. Read only.
PARSEC_PID="$(pgrep -f '^/Applications/Parsec.app/Contents/MacOS/parsecd' | head -1 || true)"

# Runs parsec-mode and checks it reports an active session for parsec. Sets LINE to its status line.
parsec_mode() {
    run_script "$PARSEC_MODE"
    timing "parsec-mode ($1)" 60
    expect_ok "parsec-mode ($1)"
    [[ "$OUT" == "parsec-mode: state=active client=parsec "* ]] || fail "parsec-mode ($1) didn't report an active session: $OUT"
    LINE="${OUT#parsec-mode: }"
}

desk_mode() {
    run_script "$DESK_MODE"
    timing "desk-mode ($1)" 60
    expect_ok "desk-mode ($1)"
}

# The ledger and the JSON status agree with a status line.
check_active() {
    local line="$1" context="$2" owner
    [ "$(ledger_value .state)" = active ] || fail "$context: the ledger is $(ledger_value .state), expected active"
    [ "$(ledger_value .client)" = parsec ] || fail "$context: the ledger's client is $(ledger_value .client)"
    for owner in "$$" $PARSEC_PID; do
        jq -e --argjson pid "$owner" '.owners | map(.pid) | index($pid)' "$(ledger)" >/dev/null ||
            fail "$context: owner $owner isn't in the ledger"
    done
    cli --json session status
    timing "session status --json" 60
    expect_ok "$context: session status --json"
    [ "$(jq -r '.json.state' <<<"$OUT")" = active ] || fail "$context: the JSON status isn't active"
    [ "$(jq -r '.json.displayID' <<<"$OUT")" = "$(field displayID "$line")" ] || fail "$context: the JSON displayID differs"
    [ "$(jq -r '.json.physicalOff | map(tostring) | join(",")' <<<"$OUT")" = "$(field off "$line")" ] ||
        fail "$context: the JSON physicalOff differs from off="
    # Every display the ledger recorded is off, and nothing else is.
    [ "$(jq -r '.physical | map(.id) | sort | map(tostring) | join(",")' "$(ledger)")" = "$(field off "$line")" ] ||
        fail "$context: off= isn't the ledger's records"
}

check_idle() {
    cli session status
    timing "session status" 60
    expect_ok "$1: session status"
    expect_out "state=idle" "$1: session status"
    [ ! -e "$(ledger)" ] || fail "$1: the ledger is still there"
}

# Two normal cycles.
for cycle in 1 2; do
    parsec_mode "cycle $cycle"
    [ "$(field lookslike "$LINE")" = 1728x1080 ] || fail "cycle $cycle started at $(field lookslike "$LINE")"
    [ "$(field pixels "$LINE")" = 3456x2160 ] || fail "cycle $cycle has pixels $(field pixels "$LINE")"
    [ "$(field hz "$LINE")" = 60 ] || fail "cycle $cycle has hz $(field hz "$LINE")"
    OFF="$(field off "$LINE")"
    [ -n "$OFF" ] || fail "cycle $cycle turned nothing off"
    check_active "$LINE" "cycle $cycle"
    eval "UUID_$cycle=\"$(field UUID "$LINE")\""
    eval "ID_$cycle=\"$(field displayID "$LINE")\""
    eval "OFF_$cycle=\"$OFF\""

    desk_mode "cycle $cycle"
    expect_out "desk-mode: done" "desk-mode (cycle $cycle)"
    check_idle "after cycle $cycle"
done
[ "$UUID_1" = "$UUID_2" ] || fail "the screen's UUID changed between sessions of one client: $UUID_1, $UUID_2"
[ "$ID_1" != "$ID_2" ] || fail "the second session's screen kept display ID $ID_1, a recreate gets a new one"
[ "$OFF_1" = "$OFF_2" ] || fail "the two cycles turned off different displays: $OFF_1, $OFF_2"
note "two cycles: screen $ID_1 then $ID_2, UUID $UUID_1, off=$OFF_1 both times"

# Out of order. desk-mode with no session is a quiet success that changes nothing.
read_plan
plan_before="$PLAN"
desk_mode "no session"
expect_out "desk-mode: done" "desk-mode with no session"
check_idle "desk-mode with no session"
read_plan
[ "$PLAN" = "$plan_before" ] || fail "desk-mode with no session changed something: $(diff <(echo "$plan_before") <(echo "$PLAN") | tr '\n' ' ')"

# parsec-mode twice. The second one is idempotent and keeps a size picked in between.
parsec_mode "first of two"
FIRST="$LINE"
check_active "$FIRST" "first of two"
owners_before="$(jq -c '.owners' "$(ledger)")"
cli session resize -lookslike=1512x945
timing "session resize" 60
expect_ok "session resize"
[ "$(field pixels "$OUT")" = 3024x1890 ] || fail "the resize gave pixels $(field pixels "$OUT")"
parsec_mode "second of two"
[ "$(field displayID "$LINE")" = "$(field displayID "$FIRST")" ] || fail "the second parsec-mode made a new screen"
[ "$(field lookslike "$LINE")" = 1512x945 ] || fail "the second parsec-mode undid the size picked: $LINE"
[ "$(field pixels "$LINE")" = 3024x1890 ] || fail "the second parsec-mode has pixels $(field pixels "$LINE")"
[ "$(field off "$LINE")" = "$OFF_1" ] || fail "the second parsec-mode changed what's off: $LINE"
check_active "$LINE" "second of two"
[ "$(jq -c '.owners' "$(ledger)")" = "$owners_before" ] || fail "the second parsec-mode, with the same owners, changed the owners"
[ "$(ledger_value .looksLike.w)x$(ledger_value .looksLike.h)" = 1512x945 ] || fail "the ledger lost the size picked"
desk_mode "after two"
expect_out "desk-mode: done" "desk-mode after parsec-mode twice"
check_idle "after parsec-mode twice"

# Another client holds the session: parsec-mode is refused and desk-mode leaves it alone.
cli session start -client=vnc -lookslike=1180x820 "-ownerpid=$$"
timing "session start (vnc)" 60
expect_ok "session start for vnc"
VNC_ID="$(field displayID "$OUT")"
parsec_refused() {
    run_script "$PARSEC_MODE"
    timing "parsec-mode (held by vnc)" 60
    expect_ok "parsec-mode while vnc holds the session"
    expect_out "parsec-mode: Failed. session held by vnc" "parsec-mode while vnc holds the session"
}
parsec_refused
desk_mode "held by vnc"
expect_out "desk-mode: left alone, Failed. session held by vnc" "desk-mode while vnc holds the session"
cli session status
expect_ok "session status while vnc holds it"
[[ "$OUT" == "state=active client=vnc displayID=$VNC_ID "* ]] || fail "desk-mode or parsec-mode disturbed vnc's session: $OUT"
cli session end -client=vnc
timing "session end (vnc)" 60
expect_ok "session end for vnc"
check_idle "after vnc"

AFTER="$(arrangement)"
[ "$AFTER" = "$BEFORE" ] || fail "the monitors came back in another mode or arrangement: before [$BEFORE] after [$AFTER]"

# Four sessions: two cycles, the out-of-order one and vnc's. Each in the safe order.
read_plan
check_sessions "$PLAN" 4 "$OFF_1"
[ "$(count_lines '^setVirtualMode ' "$PLAN")" = 1 ] || fail "the plan should resize once, in place"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"

slowest="$(sort -rn "$WORK/timings" | head -1)"
e2e_pass "2 cycles, desk-mode with no session, parsec-mode twice keeping 1512x945, both scripts refused by vnc's session; 4 sessions in the plan in the safe order, arrangement as before; slowest ${slowest%% *} s"

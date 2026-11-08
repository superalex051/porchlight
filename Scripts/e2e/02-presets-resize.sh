#!/usr/bin/env bash
# Scenario 2: every built-in preset through `session resize -preset=`, a custom size past the screen's
# max size (a recreate), a 1x size with -hidpi=off, and sizes outside the limits, which are refused.
# `session status` is checked after each. No resize may touch a physical monitor.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "02-presets-resize"

start_host

cli session presets
expect_ok "session presets"
PRESETS="$OUT"
[ "$(grep -c . <<<"$PRESETS")" = 7 ] || fail "expected the 7 built-in presets, got: $PRESETS"
# The spec's table, as session presets prints it.
expected_presets="MacBook 14: lookslike=1728x1080 pixels=3456x2160 hz=60
MacBook 14 120 Hz: lookslike=1728x1080 pixels=3456x2160 hz=120
MacBook 14 Sharpest: lookslike=1512x945 pixels=3024x1890 hz=60
MacBook 14 More Room: lookslike=1920x1200 pixels=3840x2400 hz=60
4K Screen: lookslike=1920x1080 pixels=3840x2160 hz=60
1440p Screen: lookslike=2560x1440 pixels=2560x1440 hz=60
1080p Screen: lookslike=1920x1080 pixels=1920x1080 hz=60"
[ "$PRESETS" = "$expected_presets" ] || fail "the built-in presets differ from the spec: $PRESETS"

cli session resize -preset=MacBook\ 14
expect_code 1 "resize with no session"
expect_err "Failed. no session" "resize with no session"

cli session start -client=e2e "-ownerpid=$$"
expect_ok "session start"
FIRST="$OUT"
SCREEN="$(field displayID "$FIRST")"
SCREEN_UUID="$(field UUID "$FIRST")"
OFF="$(field off "$FIRST")"
[ -n "$OFF" ] || fail "the session turned nothing off"

# Checks the line a resize printed, then the same in `session status` and its JSON.
check_size() {
    local context="$1" lookslike="$2" pixels="$3" hz="$4" line="$5"
    [ "$(field lookslike "$line")" = "$lookslike" ] || fail "$context: lookslike=$(field lookslike "$line"), expected $lookslike"
    [ "$(field pixels "$line")" = "$pixels" ] || fail "$context: pixels=$(field pixels "$line"), expected $pixels"
    [ "$(field hz "$line")" = "$hz" ] || fail "$context: hz=$(field hz "$line"), expected $hz"
    [ "$(field off "$line")" = "$OFF" ] || fail "$context: off=$(field off "$line"), the monitors changed"
    [ "$(field UUID "$line")" = "$SCREEN_UUID" ] || fail "$context: the screen's UUID changed"
    cli session status
    expect_ok "$context: session status"
    [ "$OUT" = "$line" ] || fail "$context: status [$OUT] differs from the resize's line [$line]"
    cli --json session status
    expect_ok "$context: session status --json"
    [ "$(jq -r '"\(.json.pixels.w)x\(.json.pixels.h)"' <<<"$OUT")" = "$pixels" ] || fail "$context: the JSON pixels differ"
    [ "$(jq -r '"\(.json.looksLike.w)x\(.json.looksLike.h)"' <<<"$OUT")" = "$lookslike" ] || fail "$context: the JSON looksLike differs"
    # The ledger gets the size first, so a crash recovery comes back at it.
    [ "$(ledger_value '"\(.looksLike.w)x\(.looksLike.h)"')" = "$lookslike" ] || fail "$context: the ledger has another size"
}

# Every preset, by the name session presets prints.
count=0
while IFS= read -r preset; do
    name="${preset%%: *}"
    cli session resize "-preset=$name"
    expect_ok "resize to preset $name"
    check_size "preset $name" "$(field lookslike "${preset#*: }")" "$(field pixels "${preset#*: }")" \
        "$(field hz "${preset#*: }")" "$OUT"
    [ "$(field displayID "$OUT")" = "$SCREEN" ] || fail "preset $name made a new screen, every preset fits in place"
    count=$((count + 1))
done <<<"$PRESETS"
note "$count presets, all in place on screen $SCREEN"

# Case doesn't matter in a preset's name.
cli session resize "-preset=macbook 14 SHARPEST"
expect_ok "resize to a preset named in another case"
check_size "preset in another case" 1512x945 3024x1890 60 "$OUT"

# Past the max size the screen was made with (4032x2520 for this one): a recreate, same UUID, new ID.
cli session resize -lookslike=2560x1600
expect_ok "resize past the max size"
check_size "past the max size" 2560x1600 5120x3200 60 "$OUT"
NEW_SCREEN="$(field displayID "$OUT")"
[ "$NEW_SCREEN" != "$SCREEN" ] || fail "a resize past the max size kept display ID $SCREEN, it has to recreate"
cli get "-displayID=$NEW_SCREEN" -main
expect_ok "get -main of the recreated screen"
expect_out true "the recreated screen is main"
note "past the max: screen $SCREEN recreated as $NEW_SCREEN at 5120x3200"

# A 1x size, and a size alone afterward keeps 1x.
cli session resize -lookslike=1920x1080 -hidpi=off
expect_ok "resize with -hidpi=off"
check_size "-hidpi=off" 1920x1080 1920x1080 60 "$OUT"
[ "$(ledger_value .hiDPI)" = false ] || fail "the ledger doesn't say 1x"
cli session resize -lookslike=1600x900
expect_ok "resize a 1x session by size alone"
check_size "1x by size alone" 1600x900 1600x900 60 "$OUT"
cli session resize -lookslike=1180x820 -hidpi=on -hz=120
expect_ok "resize back to HiDPI at 120 Hz"
check_size "HiDPI at 120 Hz" 1180x820 2360x1640 120 "$OUT"
# The rate alone, as the status menu's Refresh Rate does: the size and the screen stay.
cli session resize -hz=60
expect_ok "resize by the rate alone"
check_size "the rate alone" 1180x820 2360x1640 60 "$OUT"
[ "$(field displayID "$OUT")" = "$NEW_SCREEN" ] || fail "a change of rate alone made a new screen"
cli session status
expect_ok "session status before the refusals"
GOOD="$OUT"

# Refused, and the session stays as it was.
refused() {
    local context="$1" reason="$2"
    shift 2
    cli session resize "$@"
    expect_code 1 "$context"
    expect_err "Failed. $reason" "$context"
    cli session status
    expect_ok "status after $context"
    [ "$OUT" = "$GOOD" ] || fail "$context changed the session: $OUT"
}
refused "a width past the limit" "lookslike width must be 640 to 3840" -lookslike=3841x1080
refused "a height past the limit" "lookslike height must be 360 to 2400" -lookslike=1920x2401
refused "a width under the limit" "lookslike width must be 640 to 3840" -lookslike=639x480
refused "hz past the limit" "hz must be 24 to 240" -lookslike=1920x1080 -hz=241
refused "an unknown preset" "unknown preset: Nope" -preset=Nope
refused "a preset with a size" "-preset can't be combined with -lookslike, -hidpi or -hz" -preset=MacBook\ 14 -lookslike=1920x1080
refused "a size that isn't one" "invalid lookslike: big" -lookslike=big
refused "no size or rate at all" "session resize needs -lookslike, -preset or -hz" -hidpi=on
refused "a typo of a parameter" "unknown parameter: looksLikee" -looksLikee=1920x1080

cli session end -client=e2e
expect_ok "session end"
cli session status
expect_out "state=idle" "status after the end"

# One session in the plan, in the safe order, with the monitors off once and on once, so no resize
# touched them. The recreate is the one extra screen.
read_plan
check_plan_words "$PLAN"
[ "$(count_lines '^addVirtual ' "$PLAN")" = 2 ] || fail "expected the session's screen and one recreate"
[ "$(first_line "^removeVirtual $SCREEN\$" "$PLAN")" -lt "$(first_line "^addVirtual $NEW_SCREEN " "$PLAN")" ] ||
    fail "the recreate made the new screen before removing the old one"
whole="$(sed -n "$(first_line "^addVirtual $SCREEN " "$PLAN"),\$p" <<<"$PLAN")"
# Seen from the monitors' side, the session is one block: off at the start, on at the end.
[ "$(count_lines '^disable [0-9]*$' "$whole")" = "$(tr ',' '\n' <<<"$OFF" | grep -c .)" ] || fail "a resize turned a monitor off"
[ "$(count_lines '^enable [0-9]*$' "$whole")" = "$(tr ',' '\n' <<<"$OFF" | grep -c .)" ] || fail "a resize turned a monitor on"
last_disable="$(last_line '^disable ' "$PLAN")"
first_enable="$(first_line '^enable ' "$PLAN")"
for resize_line in $(awk '/^setVirtualMode / { print NR }' <<<"$PLAN"); do
    [ "$resize_line" -gt "$last_disable" ] && [ "$resize_line" -lt "$first_enable" ] ||
        fail "a resize came outside the time the monitors were off"
done
[ "$(last_line '^removeVirtual ' "$PLAN")" -gt "$(last_line '^enable ' "$PLAN")" ] || fail "the screen went before the monitors were back"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
e2e_pass "$count presets in place, case ignored, recreate past the max (screen $SCREEN to $NEW_SCREEN, same UUID, main), -hidpi=off and 1x kept, the rate alone kept the size, 9 refusals left the session alone, no resize touched a monitor"

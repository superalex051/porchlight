#!/usr/bin/env bash
# Scenario 8: the golden corpus. Scripts/compat/check-golden.sh replays its read-only rows against the
# dry-run host. It refuses the `set` rows, because it's written for the installed app. Against a dry
# run they change only the copy, so this replays them too, byte for byte, and checks the plan.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "08-golden"

CORPUS="Tests/Fixtures/Golden/cli.json"
start_host

e2e_guard
AD_CLI="$CLI" Scripts/compat/check-golden.sh >"$WORK/golden.out" 2>&1
CODE=$?
cat "$WORK/golden.out" >>"$WORK/transcript"
[ "$CODE" = 0 ] || fail "check-golden.sh exited $CODE: $(grep -A4 MISMATCH "$WORK/golden.out" | head -12 | tr '\n' ' ') $(tail -1 "$WORK/golden.out")"
SUMMARY="$(tail -1 "$WORK/golden.out")"
read_rows="$(jq '[.[] | select(.argv[0] == "get")] | length' "$CORPUS")"
[ "$SUMMARY" = "check-golden: $read_rows replayed, $(($(jq length "$CORPUS") - read_rows)) refused, 0 mismatched" ] ||
    fail "check-golden.sh's summary: $SUMMARY"
note "$SUMMARY"

# The set rows, the way check-golden.sh fills in <LG> and <M34>.
cli --json get -identifiers
expect_ok "get -identifiers"
uuid_named() { jq -r --arg name "$1" '.json[] | select(.productName == $name) | .UUID' <<<"$OUT"; }
id_named() { jq -r --arg name "$1" '.json[] | select(.productName == $name) | .displayID' <<<"$OUT"; }
LG_UUID="$(uuid_named 27GL850)"
M34_UUID="$(uuid_named M34WQ)"
M34_ID="$(id_named M34WQ)"
[ -n "$LG_UUID" ] && [ -n "$M34_UUID" ] || fail "the copy doesn't have both desk monitors"

set_rows=0
for row in $(jq -r 'range(length) as $i | select(.[$i].argv[0] == "set") | $i' "$CORPUS"); do
    argv=()
    while IFS= read -r -d '' word; do
        word="${word//<LG>/$LG_UUID}"
        argv+=("${word//<M34>/$M34_UUID}")
    done < <(jq -j --argjson row "$row" '.[$row].argv[] | ., "\u0000"' "$CORPUS")
    jq -j --argjson row "$row" '.[$row].stdout' "$CORPUS" >"$WORK/want.stdout"
    jq -j --argjson row "$row" '.[$row].stderr' "$CORPUS" >"$WORK/want.stderr"
    want_exit="$(jq --argjson row "$row" '.[$row].exit' "$CORPUS")"
    cli --no-launch "${argv[@]}"
    [ "$CODE" = "$want_exit" ] && cmp -s "$WORK/want.stdout" "$WORK/cli.out" && cmp -s "$WORK/want.stderr" "$WORK/cli.err" ||
        fail "set row ${argv[*]}: exit $CODE stdout [$OUT] stderr [$ERR], the corpus has exit $want_exit stdout [$(cat "$WORK/want.stdout")] stderr [$(cat "$WORK/want.stderr")]"
    set_rows=$((set_rows + 1))
done
[ "$set_rows" -gt 0 ] || fail "the corpus has no set rows"

# The M34WQ went off and came back on, in that order, and nothing else did.
read_plan
check_plan_words "$PLAN"
[ "$(grep -E '^(enable|disable) ' <<<"$PLAN" | tr '\n' ';')" = "disable $M34_ID;enable $M34_ID;" ] ||
    fail "the set rows' plan isn't the M34WQ off then on: $(tr '\n' ';' <<<"$PLAN")"
cli get "-UUID=$M34_UUID" -connected
expect_out on "the M34WQ after the set rows"

# And the read-only rows still hold after it came back.
AD_CLI="$CLI" Scripts/compat/check-golden.sh >"$WORK/golden-again.out" 2>&1 ||
    fail "check-golden.sh failed after the set rows: $(grep -A4 MISMATCH "$WORK/golden-again.out" | head -12 | tr '\n' ' ')"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
e2e_pass "check-golden.sh: $read_rows read-only rows matched byte for byte; the $set_rows set rows matched too against the dry run, turning the M34WQ off and on in the copy only; the read rows still matched after"

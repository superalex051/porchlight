#!/usr/bin/env bash
# Scenario 6: a corrupt safety.json and a corrupt presets.json when the host starts. The ledger is set
# aside as safety.json.corrupt, the host stays up, presets fall back to the built-in list and the bad
# file is left alone, and a session still works. Then a hand edit of presets.json applies without a
# restart, with an entry outside the limits skipped.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "06-corrupt-state"

mkdir -p "$AD_STATE_DIR" && chmod 700 "$AD_STATE_DIR" || fail "can't make the state directory"
printf '{"schemaVersion":1,"state":"act' >"$(ledger)"
printf '[{"name":"Half a preset","lookslike":' >"$AD_STATE_DIR/presets.json"
cp "$(ledger)" "$WORK/bad-ledger"
cp "$AD_STATE_DIR/presets.json" "$WORK/bad-presets"

start_host

# The host read the ledger at launch, and set the bad one aside.
[ ! -e "$(ledger)" ] || fail "safety.json is still there after the host started"
[ -f "$AD_STATE_DIR/safety.json.corrupt" ] || fail "no safety.json.corrupt"
cmp -s "$AD_STATE_DIR/safety.json.corrupt" "$WORK/bad-ledger" || fail "safety.json.corrupt isn't the bad file"
cli session status
expect_ok "session status with the ledger set aside"
expect_out "state=idle" "session status with the ledger set aside"

# The built-in list, and the bad file untouched.
cli session presets
expect_ok "session presets with a bad presets.json"
[ "$(grep -c . <<<"$OUT")" = 7 ] || fail "expected the 7 built-in presets: $OUT"
[ "$(head -1 <<<"$OUT")" = "MacBook 14: lookslike=1728x1080 pixels=3456x2160 hz=60" ] || fail "the first preset isn't the built-in default: $OUT"
cmp -s "$AD_STATE_DIR/presets.json" "$WORK/bad-presets" || fail "the host rewrote the bad presets.json"
grep -q "presets.json isn't valid, using the built-in sizes" "$AD_STATE_DIR/session.log" || fail "the bad presets.json wasn't logged"
[ ! -e "$AD_STATE_DIR/presets-version" ] || fail "a bad presets.json was marked as upgraded"

# A session works, by a built-in preset, and writes a fresh ledger.
cli session start -client=e2e -preset=MacBook\ 14\ Sharpest "-ownerpid=$$"
expect_ok "session start by a built-in preset"
[ "$(field pixels "$OUT")" = 3024x1890 ] || fail "the built-in preset gave pixels $(field pixels "$OUT")"
OFF="$(field off "$OUT")"
[ "$(ledger_value .state)" = active ] || fail "the new ledger is $(ledger_value .state)"
cmp -s "$AD_STATE_DIR/safety.json.corrupt" "$WORK/bad-ledger" || fail "the session touched safety.json.corrupt"

# The user fixes the file by hand mid-session, with one entry outside the limits. No restart.
cat >"$AD_STATE_DIR/presets.json" <<'EOF'
[
  {"name": "iPad Air", "lookslike": "1180x820", "hidpi": true, "hz": 60},
  {"name": "Too Wide", "lookslike": "5000x1000", "hidpi": false, "hz": 60},
  {"name": "Too Fast", "lookslike": "1920x1080", "hidpi": false, "hz": 500}
]
EOF
cli session presets
expect_ok "session presets after a hand edit"
# The fixed file was never upgraded, so it gets the 120 Hz preset once, at the end, as it has no
# MacBook 14. A second read adds nothing.
expect_out "iPad Air: lookslike=1180x820 pixels=2360x1640 hz=60
MacBook 14 120 Hz: lookslike=1728x1080 pixels=3456x2160 hz=120" "session presets after a hand edit"
[ "$(cat "$AD_STATE_DIR/presets-version")" = 2 ] || fail "the upgrade of the fixed presets.json wasn't recorded"
[ "$(jq -r '[.[].name] | join(",")' "$AD_STATE_DIR/presets.json")" = "iPad Air,Too Wide,Too Fast,MacBook 14 120 Hz" ] ||
    fail "the upgrade didn't keep every hand-made entry: $(cat "$AD_STATE_DIR/presets.json")"
cli session presets
expect_ok "session presets read again"
[ "$(grep -c . <<<"$OUT")" = 2 ] || fail "a second read changed the presets: $OUT"
grep -q "Skipping preset Too Wide: lookslike width must be 640 to 3840" "$AD_STATE_DIR/session.log" || fail "the too-wide entry wasn't logged"
grep -q "Skipping preset Too Fast: hz must be 24 to 240" "$AD_STATE_DIR/session.log" || fail "the too-fast entry wasn't logged"
cli session resize "-preset=ipad air"
expect_ok "resize to the hand-added preset"
[ "$(field pixels "$OUT")" = 2360x1640 ] || fail "the hand-added preset gave pixels $(field pixels "$OUT")"
cli session resize -preset=Too\ Wide
expect_code 1 "resize to a skipped preset"
expect_err "Failed. unknown preset: Too Wide" "resize to a skipped preset"

cli session end -client=e2e
expect_ok "session end"
[ ! -e "$(ledger)" ] || fail "the ledger is still there after the end"
read_plan
check_sessions "$PLAN" 1 "$OFF"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
e2e_pass "a bad safety.json became safety.json.corrupt and the host came up idle; a bad presets.json gave the 7 built-ins and was left alone; a session ran on a built-in preset; a hand edit applied without a restart, got the 120 Hz preset once, and its 2 out-of-limit entries were skipped and logged"

#!/usr/bin/env bash
# Scenario 10: `session watch`, the way another app follows a session (docs/session-api.md
# section 8.2). Two watchers, one with --json and one in text, see the idle status, then one line each for
# a start, a resize and an end, in order, each line the same as `session status` said at that moment. When
# the host quits, both exit 0 with nothing on stderr. With no host, a watch with --no-launch fails.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "10-session-watch"

# has_lines <file> <count>: the file has at least that many lines.
has_lines() {
    [ "$(wc -l <"$1" | tr -d ' ')" -ge "$2" ]
}

# line <n> <file>: the nth line.
line() {
    sed -n "$1p" "$2"
}

start_host

e2e_guard
"$CLI" --no-launch session watch --json >"$WORK/watch-json.out" 2>"$WORK/watch-json.err" &
JSON_WATCH=$!
track "$JSON_WATCH"
"$CLI" --no-launch session watch >"$WORK/watch-text.out" 2>"$WORK/watch-text.err" &
TEXT_WATCH=$!
track "$TEXT_WATCH"
wait_for 10 "the first line of both watchers" has_lines "$WORK/watch-json.out" 1
wait_for 10 "the first line of the text watcher" has_lines "$WORK/watch-text.out" 1

[ "$(line 1 "$WORK/watch-json.out")" = '{"ok":true,"payload":"state=idle","reason":null,"warning":null,"json":{"apiVersion":1,"state":"idle"}}' ] ||
    fail "the first JSON line is $(line 1 "$WORK/watch-json.out")"
[ "$(line 1 "$WORK/watch-text.out")" = state=idle ] || fail "the first text line is $(line 1 "$WORK/watch-text.out")"

# A start, as another app makes it.
cli --json session start -client=ipad -lookslike=1180x820 "-ownerpid=$$"
expect_ok "session start"
START="$OUT"
wait_for 10 "a line for the start" has_lines "$WORK/watch-json.out" 2
[ "$(line 2 "$WORK/watch-json.out")" = "$START" ] || fail "the start's line isn't what start answered: $(line 2 "$WORK/watch-json.out")"
note "start: $(jq -c '.json | {state, displayID, displayUUID, ownerPIDs}' <<<"$START")"

cli --json session resize -lookslike=1311x603
expect_ok "session resize"
RESIZED="$OUT"
wait_for 10 "a line for the resize" has_lines "$WORK/watch-json.out" 3
[ "$(line 3 "$WORK/watch-json.out")" = "$RESIZED" ] || fail "the resize's line isn't what resize answered: $(line 3 "$WORK/watch-json.out")"
[ "$(jq -c '.json.looksLike' <<<"$(line 3 "$WORK/watch-json.out")")" = '{"h":603,"w":1311}' ] || fail "the resize's line has the wrong size"

cli session end -client=ipad
expect_ok "session end"
wait_for 10 "a line for the end" has_lines "$WORK/watch-json.out" 4
[ "$(jq -c '.json' <<<"$(line 4 "$WORK/watch-json.out")")" = '{"apiVersion":1,"state":"idle"}' ] ||
    fail "the end's line is $(line 4 "$WORK/watch-json.out")"

# The text watcher saw the same four, as status lines.
wait_for 10 "the text watcher's four lines" has_lines "$WORK/watch-text.out" 4
for n in 1 2 3 4; do
    [ "$(line "$n" "$WORK/watch-text.out")" = "$(jq -r '.payload' <<<"$(line "$n" "$WORK/watch-json.out")")" ] ||
        fail "text line $n is $(line "$n" "$WORK/watch-text.out")"
done

# The host quits: both watchers exit 0, nothing more printed, nothing on stderr.
stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
for watcher in "$JSON_WATCH:json" "$TEXT_WATCH:text"; do
    pid="${watcher%%:*}"
    name="${watcher#*:}"
    wait_for 10 "the $name watcher to exit" sh -c "! kill -0 $pid 2>/dev/null"
    status=0
    wait "$pid" || status=$?
    [ "$status" = 0 ] || fail "the $name watcher exited $status"
    [ ! -s "$WORK/watch-$name.err" ] || fail "the $name watcher wrote to stderr: $(cat "$WORK/watch-$name.err")"
    [ "$(wc -l <"$WORK/watch-$name.out" | tr -d ' ')" = 4 ] || fail "the $name watcher printed $(wc -l <"$WORK/watch-$name.out" | tr -d ' ') lines"
done

cli --no-launch session watch
expect_code 1 "session watch with no host"
expect_err "Failed. app not running" "session watch with no host"
[ -z "$OUT" ] || fail "session watch with no host printed $OUT"

{
    echo "--- session watch --json"
    cat "$WORK/watch-json.out"
    echo "--- session watch"
    cat "$WORK/watch-text.out"
} >>"$WORK/transcript"
[ -z "${E2E_WATCH_OUT:-}" ] || cp "$WORK/watch-json.out" "$E2E_WATCH_OUT"

e2e_pass "two watchers (--json and text) printed idle, then one line each for start, resize and end, each equal to what that command answered; both exited 0 with nothing on stderr when the host quit; with no host, --no-launch fails with exit 1"

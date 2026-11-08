#!/usr/bin/env bash
# Scenario 3: --json on session start, status and end, and on failures from the engine, the parser
# and the CLI itself. Each answer must be one line of JSON on stdout with all five envelope keys, in
# order, nothing on stderr, and the exit code the text form would have.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "03-json"

ENVELOPE='["ok","payload","reason","warning","json"]'
# API version 1's status object, docs/session-api.md section 3.
STATUS_KEYS='["apiVersion","client","displayID","displayUUID","hiDPI","hz","looksLike","ownerPIDs","physicalOff","pixels","state"]'
IDLE_STATUS='{"apiVersion":1,"state":"idle"}'

# check_envelope <context> <ok> <exit>: one parsable line, the five keys in order, ok and exit as given.
check_envelope() {
    local context="$1" ok="$2" code="$3"
    expect_code "$code" "$context"
    expect_err "" "$context"
    [ "$(wc -l <"$WORK/cli.out" | tr -d ' ')" = 1 ] || fail "$context: stdout isn't one line: $OUT"
    jq -e . <<<"$OUT" >/dev/null 2>&1 || fail "$context: stdout isn't JSON: $OUT"
    [ "$(jq -c 'keys_unsorted' <<<"$OUT")" = "$ENVELOPE" ] || fail "$context: the keys are $(jq -c 'keys_unsorted' <<<"$OUT")"
    [ "$(jq -r '.ok' <<<"$OUT")" = "$ok" ] || fail "$context: ok is $(jq -r '.ok' <<<"$OUT")"
}

# A live session's status in .json: every key there, null where unknown.
check_status_json() {
    local context="$1"
    [ "$(jq -c '.json | keys' <<<"$OUT")" = "$STATUS_KEYS" ] || fail "$context: the status keys are $(jq -c '.json | keys' <<<"$OUT")"
}

start_host

# No session.
cli --json session status
check_envelope "status with no session" true 0
[ "$(jq -c '.json' <<<"$OUT")" = "$IDLE_STATUS" ] || fail "the idle status JSON is $(jq -c '.json' <<<"$OUT")"
[ "$(jq -r '.payload' <<<"$OUT")" = "state=idle" ] || fail "the idle payload is $(jq -r '.payload' <<<"$OUT")"

# Start, as another app would: the size, its own PID, and the screen's ID and UUID read from the JSON.
cli --json session start -client=ipad -lookslike=1180x820 "-ownerpid=$$"
check_envelope "session start" true 0
check_status_json "session start"
START="$OUT"
[ "$(jq -r '.json.state' <<<"$START")" = active ] || fail "start's state is $(jq -r '.json.state' <<<"$START")"
[ "$(jq -r '.json.client' <<<"$START")" = ipad ] || fail "start's client is $(jq -r '.json.client' <<<"$START")"
[ "$(jq -c '.json.looksLike' <<<"$START")" = '{"h":820,"w":1180}' ] || fail "start's looksLike is $(jq -c '.json.looksLike' <<<"$START")"
[ "$(jq -c '.json.pixels' <<<"$START")" = '{"h":1640,"w":2360}' ] || fail "start's pixels are $(jq -c '.json.pixels' <<<"$START")"
[ "$(jq -r '.json.hz' <<<"$START")" = 60 ] || fail "start's hz is $(jq -r '.json.hz' <<<"$START")"
[ "$(jq -r '.json.hiDPI' <<<"$START")" = true ] || fail "start's hiDPI is $(jq -r '.json.hiDPI' <<<"$START")"
[ "$(jq -r '.json.apiVersion' <<<"$START")" = 1 ] || fail "start's apiVersion is $(jq -r '.json.apiVersion' <<<"$START")"
[ "$(jq -c '.json.ownerPIDs' <<<"$START")" = "[$$]" ] || fail "start's ownerPIDs are $(jq -c '.json.ownerPIDs' <<<"$START")"
jq -e '.json.displayID | type == "number"' <<<"$START" >/dev/null || fail "start's displayID isn't a number"
jq -e '.json.displayUUID | test("^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")' <<<"$START" >/dev/null ||
    fail "start's displayUUID isn't a UUID: $(jq -r '.json.displayUUID' <<<"$START")"
jq -e '.json.physicalOff | length > 0 and all(type == "number")' <<<"$START" >/dev/null || fail "start's physicalOff is $(jq -c '.json.physicalOff' <<<"$START")"
[ "$(jq -r '.reason' <<<"$START")" = null ] && [ "$(jq -r '.warning' <<<"$START")" = null ] ||
    fail "a clean start has a reason or a warning"
SCREEN="$(jq -r '.json.displayID' <<<"$START")"
SCREEN_UUID="$(jq -r '.json.displayUUID' <<<"$START")"
# The text line and the JSON say the same thing.
[ "$(jq -r '.payload' <<<"$START")" = "state=active client=ipad displayID=$SCREEN UUID=$SCREEN_UUID lookslike=1180x820 pixels=2360x1640 hz=60 off=$(jq -r '.json.physicalOff | map(tostring) | join(",")' <<<"$START")" ] ||
    fail "start's payload doesn't match its JSON: $(jq -r '.payload' <<<"$START")"

# The ID a caller would capture is the screen the copy has as main.
cli get "-displayID=$SCREEN" -main
expect_ok "get -main of the session's screen"
expect_out true "the session's screen is main"
cli get "-UUID=$SCREEN_UUID" -resolution
expect_ok "get -resolution of the session's screen by UUID"
expect_out 1180x820 "the session's screen by UUID"

cli --json session status
check_envelope "session status" true 0
check_status_json "session status"
[ "$(jq -c '.json' <<<"$OUT")" = "$(jq -c '.json' <<<"$START")" ] || fail "status differs from start: $(jq -c '.json' <<<"$OUT")"

# Failures. The engine's, with a reason.
cli --json session start -client=iphone -lookslike=1311x603
check_envelope "a start from another client" false 1
[ "$(jq -r '.reason' <<<"$OUT")" = "session held by ipad" ] || fail "the refusal's reason is $(jq -r '.reason' <<<"$OUT")"
[ "$(jq -r '.payload' <<<"$OUT")" = null ] && [ "$(jq -r '.json' <<<"$OUT")" = null ] || fail "a refusal carries a payload or json"

cli --json session resize -lookslike=4000x2000
check_envelope "a resize past the limit" false 1
[ "$(jq -r '.reason' <<<"$OUT")" = "lookslike width must be 640 to 3840" ] || fail "the limit's reason is $(jq -r '.reason' <<<"$OUT")"

# A BetterDisplay-compatible failure: no reason at all, so null.
cli --json get -UUID=00000000-0000-0000-0000-000000000000 -connected
check_envelope "get on an unknown UUID" false 1
[ "$(jq -r '.reason' <<<"$OUT")" = null ] || fail "a bare failure has reason $(jq -r '.reason' <<<"$OUT")"

# The parser's, with --json after the bad argument.
cli session status --timeout=0 --json
check_envelope "a bad --timeout" false 1
[ "$(jq -r '.reason' <<<"$OUT")" = "--timeout needs a positive number of seconds, at most 86400" ] || fail "the parser's reason is $(jq -r '.reason' <<<"$OUT")"

# A typo like -json for --json is an unknown parameter, and must not start anything.
cli session start -client=ipad -json
expect_code 1 "session start with -json"
expect_err "Failed. unknown parameter: json" "session start with -json"

# Ending, then the CLI's own failure with no host.
cli --json session end -client=ipad
check_envelope "session end" true 0
[ "$(jq -r '.payload' <<<"$OUT")" = null ] || fail "end has a payload: $(jq -r '.payload' <<<"$OUT")"
[ "$(jq -c '.json' <<<"$OUT")" = "$IDLE_STATUS" ] || fail "end's status JSON is $(jq -c '.json' <<<"$OUT")"
cli --json session status
check_envelope "status after the end" true 0
[ "$(jq -c '.json' <<<"$OUT")" = "$IDLE_STATUS" ] || fail "the session didn't end: $(jq -c '.json' <<<"$OUT")"

# The refusals changed nothing: one session in the plan, in the safe order.
read_plan
check_sessions "$PLAN" 1 "$(jq -r '.json.physicalOff | map(tostring) | join(",")' <<<"$START")"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"
cli --json session status
check_envelope "status with no host" false 1
[ "$(jq -r '.reason' <<<"$OUT")" = "app not running" ] || fail "with no host the reason is $(jq -r '.reason' <<<"$OUT")"

e2e_pass "start, status and end parse with all five keys in order and every API version 1 status key, idle is {\"apiVersion\":1,\"state\":\"idle\"}; refusals from the engine, the parser and the CLI (no host) parse too, with exit 1 and nothing on stderr; the JSON's displayID and displayUUID name the main screen"

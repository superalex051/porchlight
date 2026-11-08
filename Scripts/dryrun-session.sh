#!/usr/bin/env bash
# The whole session flow on a simulated copy of this Mac. It changes no real display.
# Builds, starts addevhost in a dry run on throwaway paths, runs the commands of parsec-mode and
# desk-mode with a resize and a status between them, then prints the plan and checks it. Reads the real
# displays with `displayplacer list` before and after, which is the only other thing it asks of them.
# Exit 0: the flow worked and the plan is right. Anything else: it says why.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "dryrun-session: FAILED: $1" >&2
    exit 1
}

command -v displayplacer >/dev/null || fail "displayplacer is needed to compare the real displays"

swift build --product addevhost
swift build --product porchlight
BIN="$(swift build --show-bin-path)"
CLI="$BIN/porchlight"

WORK="$(mktemp -d -t ad-dryrun)"
HOST_PID=""
HOST_STATUS=""

# Stopped by signal, so it ends any session it holds and takes its socket with it.
stop_host() {
    [ -n "$HOST_PID" ] || return 0
    kill -TERM "$HOST_PID" 2>/dev/null || true
    for _ in $(seq 1 150); do
        kill -0 "$HOST_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$HOST_PID" 2>/dev/null || true
    HOST_STATUS=0
    wait "$HOST_PID" 2>/dev/null || HOST_STATUS=$?
    HOST_PID=""
}

finish() {
    local status=$?
    trap - EXIT
    stop_host
    if [ "$status" -ne 0 ] && [ -s "$WORK/host.log" ]; then
        echo "dryrun-session: what the host said:" >&2
        cat "$WORK/host.log" >&2
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM HUP

displayplacer list >"$WORK/real-before.txt"

export AD_DRY_RUN=1
export AD_STATE_DIR="$WORK/state"
export AD_SOCKET_PATH="$WORK/ctl.sock"

"$BIN/addevhost" >"$WORK/host.log" 2>&1 &
HOST_PID=$!

answered=""
for _ in $(seq 1 150); do
    kill -0 "$HOST_PID" 2>/dev/null || fail "the host exited before it was ready"
    if [ "$("$CLI" ping --timeout=1 2>/dev/null || true)" = "pong" ]; then
        answered=yes
        break
    fi
    sleep 0.1
done
[ -n "$answered" ] || fail "the host never answered"

# Shows the command and its output, and leaves the output in OUTPUT.
run() {
    echo "\$ porchlight $*"
    OUTPUT="$("$CLI" "$@")" || fail "porchlight $* exited with $?"
    if [ -n "$OUTPUT" ]; then echo "$OUTPUT"; fi
}

display_ids() {
    sed -n 's/.*"displayID" : "\([0-9]*\)".*/\1/p'
}

# Every display that's on, with its mode and where it sits. A display that's off has no mode to read,
# so it fails, and isn't listed.
display_arrangement() {
    local id reading
    for id in $("$CLI" get -identifiers | display_ids); do
        reading="$("$CLI" get "-displayID=$id" -resolution -refreshRate -placement 2>/dev/null || true)"
        if [ -n "$reading" ]; then echo "display $id: $reading"; fi
    done
}

# What the monitors should come back to. A restore sets a recorded mode only where it differs, and a
# simulated monitor keeps its mode while it's off, so the plan has no mode line for it, and this read
# is what shows the recorded rates held.
BEFORE="$(display_arrangement)"
echo "Before the session:"
echo "$BEFORE"
OLD_MAIN="$("$CLI" get -displayWithMainStatus -identifiers | display_ids)" || fail "can't read which display is main"

# parsec-mode's start, at a fixed size: parsec-mode itself asks for -preset=auto, which reads Parsec's files
# and is covered by e2e scenario 11. This script's own PID stands in for the watcher: alive throughout,
# and nothing to anyone else.
run session start -client=parsec -lookslike=1728x1080 "-ownerpid=$$"
[[ "$OUTPUT" == "state=active client=parsec "* ]] || fail "the session didn't start"
[[ "$OUTPUT" == *" lookslike=1728x1080 pixels=3456x2160 hz=60 off="* ]] || fail "the session started at the wrong size"
OFF="${OUTPUT##* off=}"
[ -n "$OFF" ] || fail "the session turned nothing off"
SCREEN="${OUTPUT#* displayID=}"
SCREEN="${SCREEN%% *}"

run session resize -lookslike=1512x945
[[ "$OUTPUT" == *" lookslike=1512x945 pixels=3024x1890 hz=60 off=$OFF" ]] || fail "the resize didn't take, or touched a monitor"

run session status
[[ "$OUTPUT" == "state=active client=parsec "*" lookslike=1512x945 "* ]] || fail "the status doesn't show the resized session"

# desk-mode
run session end -client=parsec
run session status
[ "$OUTPUT" = "state=idle" ] || fail "the session didn't end"

AFTER="$(display_arrangement)"
echo "After the session:"
echo "$AFTER"
[ "$AFTER" = "$BEFORE" ] || fail "the monitors came back in another mode or arrangement"
for id in ${OFF//,/ }; do
    grep -q "^display $id: " <<<"$AFTER" || fail "display $id isn't back on"
done

run get -dryRunPlan
PLAN="$OUTPUT"

first_line() { awk -v wanted="$1" '$0 ~ wanted { print NR; exit }' <<<"$PLAN"; }
last_line() { awk -v wanted="$1" '$0 ~ wanted { found = NR } END { if (found) print found }' <<<"$PLAN"; }

# The simulator's own words and nothing else, so no line can be about anything but the copy.
strange="$(grep -vE '^(addVirtual|removeVirtual|setVirtualMode|gone|enable|disable|commit) ' <<<"$PLAN" || true)"
[ -z "$strange" ] || fail "the plan has a line the simulator doesn't write: $strange"
if grep -qiE 'hardware|real display' <<<"$PLAN"; then
    fail "a line in the plan says something was done to hardware"
fi

created="$(first_line '^addVirtual ')"
destroyed="$(last_line '^removeVirtual ')"
[ -n "$created" ] || fail "the plan never creates a screen"
[ -n "$destroyed" ] || fail "the plan never destroys the screen"
[ -n "$(first_line '^setVirtualMode .*1512x945')" ] || fail "the plan never resizes the screen"

# Main is whichever display sits at (0,0).
made_main="$(first_line "^commit .*origin $SCREEN [(]0,0[)]")"
[ -n "$made_main" ] || fail "the plan never makes the screen main"
[ "$created" -lt "$made_main" ] || fail "the plan makes the screen main before it exists"

for id in ${OFF//,/ }; do
    off="$(first_line "^disable $id\$")"
    on="$(last_line "^enable $id\$")"
    [ -n "$off" ] || fail "display $id never goes off"
    [ -n "$on" ] || fail "display $id never comes back"
    [ "$made_main" -lt "$off" ] || fail "display $id goes off before the screen is main"
    [ "$off" -lt "$on" ] || fail "display $id comes back before it goes off"
    [ "$on" -lt "$destroyed" ] || fail "the screen goes before display $id is back"
done

# The main display may be something a session leaves on, such as a virtual screen. Then there's no
# order to check, and the closing line says so.
case ",$OFF," in
    *",$OLD_MAIN,"*)
        [ "$(last_line '^disable ')" = "$(last_line "^disable $OLD_MAIN\$")" ] || fail "the old main isn't the last to go off"
        [ "$(first_line '^enable ')" = "$(first_line "^enable $OLD_MAIN\$")" ] || fail "the old main isn't the first back on"
        MAIN_ORDER="the old main went off last and came back first"
        ;;
    *)
        MAIN_ORDER="the old main isn't a monitor this session turned off, so its order wasn't checked"
        ;;
esac

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with status $HOST_STATUS"

displayplacer list >"$WORK/real-after.txt"
if ! diff "$WORK/real-before.txt" "$WORK/real-after.txt"; then
    fail "displayplacer list changed during the run. Nothing here should do that, though a person or a display going to sleep can"
fi

echo "dryrun-session: OK."
echo "  On the simulated copy: the screen became main before any monitor went off, $MAIN_ORDER, and the monitors came back with the same modes and arrangement."
echo "  On this Mac: displayplacer list read the same before and after, and the host stopped with status 0."

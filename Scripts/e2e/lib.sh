# Shared by the scenarios in Scripts/e2e. Sourced, never run on its own.
#
# Every scenario runs on a simulated copy of this Mac: `addevhost` in a dry run, on a state directory
# and a socket inside a throwaway work directory, with the CLI and `porchlight-guardian` from
# `.build`. The variables that make it a dry run are exported before any program is found, and every
# program runs through a wrapper that checks them again first. Nothing here starts the real app, runs
# a live restore or posts an input event. The host reads Parsec's log and config from the work directory,
# where they don't exist unless a scenario writes them, never from ~/.parsec, so what Parsec did last on
# this Mac can't change a scenario's sizes. The real displays are only read, with `displayplacer list`,
# before and after, and the scenario fails if that reading changed.
#
# A scenario calls `e2e_begin <name>`, does its work, and ends with `e2e_pass "<summary>"`. Any check
# that fails calls `fail "<reason>"`. Either way the exit trap stops what the scenario started, deletes
# the work directory, and prints one line: `PASS <name>: ...` or `FAIL <name>: ...`.
#
# E2E_BUILT=1 skips the build, for `run-all.sh`, which builds once. E2E_KEEP=1 keeps the work directory.

E2E_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

E2E_NAME=""
WORK=""
HOST_PID=""
HOST_STATUS=""
GUARDIAN_PID=""
E2E_PIDS=""
E2E_RESULT=""
E2E_SUMMARY=""
E2E_REASON=""

OUT=""
ERR=""
CODE=""
SECS=""

# Seconds since some fixed point, to the millisecond, from a clock that doesn't jump.
now() {
    perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.3f\n", clock_gettime(CLOCK_MONOTONIC)'
}

elapsed() {
    perl -e 'printf "%.3f\n", $ARGV[1] - $ARGV[0]' "$1" "$2"
}

# True if the first number is less than the second.
less_than() {
    perl -e 'exit !($ARGV[0] < $ARGV[1])' "$1" "$2"
}

fail() {
    E2E_REASON="$1"
    exit 1
}

e2e_pass() {
    E2E_SUMMARY="$1"
    E2E_RESULT=pass
    exit 0
}

note() {
    echo "  $*"
}

e2e_begin() {
    E2E_NAME="$1"
    cd "$E2E_REPO" || exit 2
    trap e2e_finish EXIT
    trap 'E2E_REASON="${E2E_REASON:-interrupted}"; exit 1' INT TERM HUP

    if [ -n "${AD_HIL+set}" ]; then
        fail "AD_HIL is set. These scenarios are dry runs only, so unset it"
    fi
    local tool
    for tool in jq displayplacer perl zsh; do
        command -v "$tool" >/dev/null || fail "$tool is needed"
    done

    WORK="$(mktemp -d -t ad-e2e)" || fail "can't make a work directory"
    # The dry run, before anything else can run. Nothing below may run without these.
    export AD_DRY_RUN=1
    export AD_STATE_DIR="$WORK/state"
    export AD_SOCKET_PATH="$WORK/ctl.sock"
    export AD_PARSEC_LOG="$WORK/parsec-log.txt"
    export AD_PARSEC_CONFIG="$WORK/parsec-config.json"

    if [ "${E2E_BUILT:-}" != 1 ]; then
        local product
        for product in addevhost porchlight porchlight-guardian; do
            swift build --product "$product" >"$WORK/build.log" 2>&1 ||
                fail "swift build --product $product failed: $(tail -5 "$WORK/build.log" | tr '\n' ' ')"
        done
    fi
    BIN="$(swift build --show-bin-path)" || fail "can't find the build directory"
    HOST="$BIN/addevhost"
    REAL_CLI="$BIN/porchlight"
    GUARDIAN="$BIN/porchlight-guardian"
    for tool in "$HOST" "$REAL_CLI" "$GUARDIAN"; do
        [ -x "$tool" ] || fail "not built: $tool"
    done
    export AD_GUARDIAN_PATH="$GUARDIAN"

    # Called the way the scripts call it on this Mac, through a link, which is how the CLI finds
    # `porchlight-guardian` for a rescue. The work directory's path has no spaces, so the zsh
    # scripts' unquoted `$AD` stays one word.
    mkdir -p "$WORK/bin" || fail "can't make $WORK/bin"
    ln -s "$REAL_CLI" "$WORK/bin/porchlight" || fail "can't link the CLI"
    CLI="$WORK/bin/porchlight"

    displayplacer list >"$WORK/real-before.txt" 2>&1 || fail "displayplacer list failed"
    echo "== $E2E_NAME"
}

# Refuses to go on unless this is still a dry run on the work directory's own paths.
e2e_guard() {
    [ -n "$WORK" ] || { echo "e2e: no work directory, refusing to run anything" >&2; exit 2; }
    case "${AD_STATE_DIR:-}" in "$WORK"/*) ;; *) echo "e2e: AD_STATE_DIR left the work directory, refusing" >&2; exit 2 ;; esac
    case "${AD_SOCKET_PATH:-}" in "$WORK"/*) ;; *) echo "e2e: AD_SOCKET_PATH left the work directory, refusing" >&2; exit 2 ;; esac
    [ "${AD_DRY_RUN:-}" = 1 ] || { echo "e2e: AD_DRY_RUN isn't 1, refusing" >&2; exit 2; }
}

# Runs one CLI command. Sets OUT and ERR (trailing newlines removed), CODE and SECS, and adds the
# command to the transcript that a failure prints.
cli() {
    e2e_guard
    local started ended
    started="$(now)"
    "$CLI" "$@" >"$WORK/cli.out" 2>"$WORK/cli.err"
    CODE=$?
    ended="$(now)"
    SECS="$(elapsed "$started" "$ended")"
    OUT="$(cat "$WORK/cli.out")"
    ERR="$(cat "$WORK/cli.err")"
    {
        echo "\$ porchlight $*    (exit $CODE, $SECS s)"
        [ -z "$OUT" ] || echo "$OUT" | sed 's/^/  out: /'
        [ -z "$ERR" ] || echo "$ERR" | sed 's/^/  err: /'
    } >>"$WORK/transcript"
}

# Runs a script with the dry-run environment. Sets OUT, ERR, CODE and SECS the same way.
run_script() {
    e2e_guard
    local started ended
    started="$(now)"
    "$@" >"$WORK/cli.out" 2>"$WORK/cli.err"
    CODE=$?
    ended="$(now)"
    SECS="$(elapsed "$started" "$ended")"
    OUT="$(cat "$WORK/cli.out")"
    ERR="$(cat "$WORK/cli.err")"
    {
        echo "\$ $(basename "$1") ${*:2}    (exit $CODE, $SECS s)"
        [ -z "$OUT" ] || echo "$OUT" | sed 's/^/  out: /'
        [ -z "$ERR" ] || echo "$ERR" | sed 's/^/  err: /'
    } >>"$WORK/transcript"
}

# Records how long the last command took, against the limit the CLI holds it to.
timing() {
    local label="$1" limit="$2"
    echo "$SECS $limit $label" >>"$WORK/timings"
    if [ -n "${E2E_TIMINGS:-}" ]; then echo "$SECS $limit $label" >>"$E2E_TIMINGS"; fi
}

expect_code() {
    [ "$CODE" = "$1" ] || fail "$2: exit $CODE, expected $1 (stdout [$OUT], stderr [$ERR])"
}

expect_out() {
    [ "$OUT" = "$1" ] || fail "$2: stdout [$OUT], expected [$1]"
}

expect_err() {
    [ "$ERR" = "$1" ] || fail "$2: stderr [$ERR], expected [$1]"
}

# The command worked, with its payload on stdout and nothing on stderr.
expect_ok() {
    expect_code 0 "$1"
    expect_err "" "$1"
}

# The status line's field, or empty.
field() {
    local name="$1" line="$2" word
    for word in $line; do
        case "$word" in "$name="*) echo "${word#*=}"; return ;; esac
    done
}

start_host() {
    e2e_guard
    "$HOST" >>"$WORK/host.log" 2>&1 &
    HOST_PID=$!
    local tries
    for tries in $(seq 1 150); do
        kill -0 "$HOST_PID" 2>/dev/null || fail "the host exited before it was ready: $(cat "$WORK/host.log")"
        if [ "$("$CLI" --no-launch --timeout=1 ping 2>/dev/null)" = pong ]; then
            require_desk
            return 0
        fi
        sleep 0.1
    done
    fail "the host never answered a ping"
}

# The copy is made from the real Mac when the host starts. If a real session is running then, with the
# monitors off and a real screen up, the copy isn't the desk and every check below would be about the
# wrong thing. That's said plainly instead.
require_desk() {
    "$CLI" --no-launch --json get -identifiers >"$WORK/identifiers.json" 2>/dev/null ||
        fail "get -identifiers failed on the copy"
    if jq -e '.json | any(.deviceType == "VirtualScreen" and (.name | startswith("Porch Light")))' \
        "$WORK/identifiers.json" >/dev/null; then
        fail "the real Mac has a Porch Light screen up, so a real session was running when the copy was made. Run this again once the desk is back"
    fi
    "$CLI" --no-launch get -displayWithMainStatus -identifiers >"$WORK/main.json" 2>/dev/null ||
        fail "the copy has no main display"
    grep -q '"deviceType" : "Display"' "$WORK/main.json" ||
        fail "the copy's main display isn't a monitor, so the real Mac wasn't at the desk when the copy was made. Run this again once it is"
}

# Orderly, by SIGTERM, which ends any session the host holds. Sets HOST_STATUS.
stop_host() {
    [ -n "$HOST_PID" ] || return 0
    kill -TERM "$HOST_PID" 2>/dev/null || true
    local tries
    for tries in $(seq 1 150); do
        kill -0 "$HOST_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$HOST_PID" 2>/dev/null || true
    HOST_STATUS=0
    wait "$HOST_PID" 2>/dev/null || HOST_STATUS=$?
    HOST_PID=""
}

# A crash: SIGKILL, so the host can't end its session or take its socket away.
crash_host() {
    [ -n "$HOST_PID" ] || fail "no host to kill"
    kill -KILL "$HOST_PID" 2>/dev/null || fail "the host was already gone"
    wait "$HOST_PID" 2>/dev/null || true
    HOST_PID=""
}

# `porchlight-guardian` watching this state directory, its output in guardian.log. In a dry run it never
# starts the real app or posts a notification, and its restores are dry runs too. It can still show its
# alert window, if its restores keep failing or it can't read the ledger, and a window changes nothing.
start_guardian() {
    e2e_guard
    "$GUARDIAN" >>"$WORK/guardian.log" 2>&1 &
    GUARDIAN_PID=$!
    local tries
    for tries in $(seq 1 100); do
        kill -0 "$GUARDIAN_PID" 2>/dev/null || fail "the guardian exited: $(cat "$WORK/guardian.log")"
        if [ "$(AD_SOCKET_PATH="$AD_STATE_DIR/guardian.sock" "$CLI" --no-launch --timeout=1 ping 2>/dev/null)" = pong ]; then
            return 0
        fi
        sleep 0.1
    done
    fail "the guardian never answered a ping"
}

stop_guardian() {
    [ -n "$GUARDIAN_PID" ] || return 0
    # A restore child has its own process group, so it's stopped by name of its parent.
    pkill -TERM -P "$GUARDIAN_PID" 2>/dev/null || true
    kill -TERM "$GUARDIAN_PID" 2>/dev/null || true
    local tries
    for tries in $(seq 1 50); do
        kill -0 "$GUARDIAN_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL "$GUARDIAN_PID" 2>/dev/null || true
    wait "$GUARDIAN_PID" 2>/dev/null || true
    GUARDIAN_PID=""
}

# A process the scenario started and the trap must stop.
track() {
    E2E_PIDS="$E2E_PIDS $1"
}

# wait_for <seconds> <description> <command...>: polls every quarter second until the command succeeds.
wait_for() {
    local limit="$1" what="$2" started
    shift 2
    started="$(now)"
    while ! "$@"; do
        less_than "$(elapsed "$started" "$(now)")" "$limit" || fail "$what didn't happen within $limit s"
        sleep 0.25
    done
}

ledger() {
    echo "$AD_STATE_DIR/safety.json"
}

# A field of safety.json, or `none` with no file.
ledger_value() {
    if [ -f "$(ledger)" ]; then jq -r "$1" "$(ledger)"; else echo none; fi
}

# Sets PLAN from `get -dryRunPlan`.
read_plan() {
    cli get -dryRunPlan
    expect_ok "get -dryRunPlan"
    PLAN="$OUT"
}

first_line() { awk -v wanted="$1" '$0 ~ wanted { print NR; exit }' <<<"$2"; }
last_line() { awk -v wanted="$1" '$0 ~ wanted { found = NR } END { if (found) print found }' <<<"$2"; }
count_lines() { awk -v wanted="$1" '$0 ~ wanted { n++ } END { print n + 0 }' <<<"$2"; }

# The simulator's own words and nothing else, so no line can be about anything but the copy.
check_plan_words() {
    local strange
    strange="$(grep -vE '^(addVirtual|removeVirtual|setVirtualMode|gone|enable|disable|commit) ' <<<"$1" || true)"
    [ -z "$strange" ] || fail "the plan has a line the simulator doesn't write: $strange"
}

# check_session_block <block> <off ids, comma separated>: in one session's part of the plan, the screen
# exists before it's main, it's main before any monitor goes off, every monitor goes off once and comes
# back once, and the screen goes only after they're all back. So a resize in between touched no monitor.
check_session_block() {
    local block="$1" off="$2" screen created made_main destroyed id off_at on_at wanted
    wanted="$(tr ',' '\n' <<<"$off" | grep -c . || true)"
    [ "$(count_lines '^disable [0-9]*$' "$block")" = "$wanted" ] || fail "a session turns monitors off $(count_lines '^disable [0-9]*$' "$block") times, expected $wanted: $(tr '\n' ';' <<<"$block")"
    [ "$(count_lines '^enable [0-9]*$' "$block")" = "$wanted" ] || fail "a session turns monitors on $(count_lines '^enable [0-9]*$' "$block") times, expected $wanted: $(tr '\n' ';' <<<"$block")"
    screen="$(awk '/^addVirtual / { print $2; exit }' <<<"$block")"
    [ -n "$screen" ] || fail "a session in the plan never creates a screen"
    created="$(first_line '^addVirtual ' "$block")"
    made_main="$(first_line "^commit .*origin $screen [(]0,0[)]" "$block")"
    destroyed="$(last_line "^removeVirtual $screen\$" "$block")"
    [ -n "$made_main" ] || fail "the plan never makes screen $screen main"
    [ -n "$destroyed" ] || fail "the plan never removes screen $screen"
    [ "$created" -lt "$made_main" ] || fail "screen $screen is main before it exists"
    for id in ${off//,/ }; do
        off_at="$(first_line "^disable $id\$" "$block")"
        on_at="$(last_line "^enable $id\$" "$block")"
        [ -n "$off_at" ] || fail "display $id never goes off in the session with screen $screen"
        [ -n "$on_at" ] || fail "display $id never comes back in the session with screen $screen"
        [ "$made_main" -lt "$off_at" ] || fail "display $id goes off before screen $screen is main"
        [ "$off_at" -lt "$on_at" ] || fail "display $id comes back before it goes off"
        [ "$on_at" -lt "$destroyed" ] || fail "screen $screen goes before display $id is back"
    done
}

# check_sessions <plan> <expected sessions> <off ids>: the plan holds exactly that many sessions, one
# block per `addVirtual`, and each passes `check_session_block`.
check_sessions() {
    local plan="$1" expected="$2" off="$3" starts total total_lines index first next block
    check_plan_words "$plan"
    starts="$(awk '/^addVirtual / { print NR }' <<<"$plan")"
    total="$(echo "$starts" | grep -c . || true)"
    [ "$total" = "$expected" ] || fail "the plan has $total sessions, expected $expected"
    total_lines="$(echo "$plan" | wc -l | tr -d ' ')"
    index=0
    for first in $starts; do
        index=$((index + 1))
        next="$(echo "$starts" | sed -n "$((index + 1))p")"
        if [ -n "$next" ]; then
            block="$(sed -n "${first},$((next - 1))p" <<<"$plan")"
        else
            block="$(sed -n "${first},${total_lines}p" <<<"$plan")"
        fi
        check_session_block "$block" "$off"
    done
}

# Every display that's on, with its mode and where it sits. A display that's off has no mode to read,
# so it isn't listed.
arrangement() {
    e2e_guard
    local id reading
    for id in $("$CLI" --no-launch get -identifiers | sed -n 's/.*"displayID" : "\([0-9]*\)".*/\1/p'); do
        reading="$("$CLI" --no-launch get "-displayID=$id" -resolution -refreshRate -placement 2>/dev/null || true)"
        if [ -n "$reading" ]; then echo "display $id: $reading"; fi
    done
}

e2e_finish() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e

    stop_guardian
    stop_host
    local pid
    for pid in $E2E_PIDS; do
        kill -KILL "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done

    if [ -n "$WORK" ] && [ -f "$WORK/real-before.txt" ]; then
        displayplacer list >"$WORK/real-after.txt" 2>&1
        if ! cmp -s "$WORK/real-before.txt" "$WORK/real-after.txt"; then
            status=1
            E2E_RESULT=""
            E2E_REASON="displayplacer list changed during the run. Nothing here should do that, though a person or a display going to sleep can: $(diff "$WORK/real-before.txt" "$WORK/real-after.txt" | head -5 | tr '\n' ' ')"
        fi
    fi

    if [ "$status" -eq 0 ] && [ "$E2E_RESULT" = pass ]; then
        echo "PASS $E2E_NAME: $E2E_SUMMARY"
    else
        [ "$status" -ne 0 ] || status=1
        if [ -n "$WORK" ]; then
            for log in transcript host.log guardian.log helper.log; do
                if [ -s "$WORK/$log" ]; then
                    echo "--- $log (last 60 lines)"
                    tail -60 "$WORK/$log"
                fi
            done
            if [ -s "$WORK/state/session.log" ]; then
                echo "--- session.log"
                tail -30 "$WORK/state/session.log"
            fi
        fi
        echo "FAIL $E2E_NAME: ${E2E_REASON:-exited with status $status}"
    fi

    if [ -n "$WORK" ] && [ "${E2E_KEEP:-}" != 1 ]; then rm -rf "$WORK"; fi
    exit "$status"
}

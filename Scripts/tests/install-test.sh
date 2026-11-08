#!/usr/bin/env bash
# Tests Scripts/install.sh without touching this Mac. Each scenario runs in its own fake root
# (PL_INSTALL_ROOT) and fake home (HOME) under a temp directory. launchctl, pgrep, codesign and plutil
# are stubs first on PATH that record their arguments, and the built app is a fake one named by
# PL_BUILT_APP: a folder with a stub CLI in it.
#
# Scenarios: (a) a first install with the guardian and the CLI link, (b) a live session stops the
# install, and --end-session ends it, (c) a reinstall leaves a loaded guardian alone without --guardian,
# and restarts it with --guardian, (d) the fake-system guard refuses the real home and the real launchctl.
#
# Exit 0: every check passed. Exit 1: a check failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO/Scripts/install.sh"

LABEL="com.alexluncan.PorchLight.guardian"
MARK="the built Porch Light app"

TOP="$(mktemp -d -t pl-install-test)" || exit 1
trap 'rm -rf "$TOP"' EXIT

CHECKS=0
OUT=""
CODE=""
LAST_RUN=""

fail() {
    echo "install-test: FAIL: $1" >&2
    if [ -n "$LAST_RUN" ]; then
        echo "--- the last run: $LAST_RUN (exit $CODE)" >&2
        echo "$OUT" >&2
    fi
    exit 1
}

# check <what> <command...>: the command must succeed.
check() {
    local what="$1"
    shift
    "$@" || fail "$what"
    CHECKS=$((CHECKS + 1))
    echo "  ok: $what"
}

has_line() {
    grep -qxF -- "$2" "$1"
}

said() {
    grep -qF -- "$1" <<<"$OUT"
}

not_said() {
    ! grep -qF -- "$1" <<<"$OUT"
}

# Every file and folder with its mode, and every file's contents, so a later reading shows any change.
snapshot() {
    (
        cd "$1" || exit 1
        find . -exec stat -f '%Sp %N' {} + | sort
        find . -type f -exec shasum {} + | sort
    )
}

# The fake root and home, which is everything install.sh may change. The stubs' logs are left out.
world_snapshot() {
    snapshot "$ROOT"
    snapshot "$HOME_DIR"
}

# Sets the world's paths: W, ROOT, HOME_DIR, STUBS, STATE, BUILT, INSTALLED and AGENTS.
use_world() {
    W="$TOP/$1"
    ROOT="$W/root"
    HOME_DIR="$W/home"
    STUBS="$W/stubs"
    STATE="$W/stub-state"
    BUILT="$W/build/PorchLight.app"
    INSTALLED="$ROOT/Applications/PorchLight.app"
    AGENTS="$HOME_DIR/Library/LaunchAgents"
}

# make_cli <path>: a CLI that answers what install.sh asks. `session status` prints the session file, or
# state=idle. `session end` makes it idle. `quit` makes the process stop running.
make_cli() {
    mkdir -p "$(dirname "$1")"
    cat >"$1" <<EOF
#!/bin/bash
state="$STATE"
echo "\$*" >>"\$state/cli.log"
echo "cli \$*" >>"\$state/calls.log"
case "\$1 \${2:-}" in
    "session status") if [ -f "\$state/session" ]; then cat "\$state/session"; else echo state=idle; fi ;;
    "session end") echo state=idle >"\$state/session" ;;
    "quit "*) rm -f "\$state/running/PorchLight" ;;
    *) echo "unexpected: \$*" >&2; exit 64 ;;
esac
EOF
    chmod +x "$1"
}

# make_app <path> <mark>: the app, its guardian and its CLI, as stubs.
make_app() {
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Helpers"
    printf '#!/bin/sh\nexit 0\n' >"$1/Contents/MacOS/PorchLight"
    printf '#!/bin/sh\nexit 0\n' >"$1/Contents/Helpers/porchlight-guardian"
    chmod +x "$1/Contents/MacOS/PorchLight" "$1/Contents/Helpers/porchlight-guardian"
    make_cli "$1/Contents/Helpers/porchlight"
    echo "$2" >"$1/Contents/mark"
}

make_stubs() {
    mkdir -p "$STUBS" "$STATE/running" "$STATE/loaded"
    : >"$STATE/launchctl.log"
    : >"$STATE/pgrep.log"
    : >"$STATE/cli.log"
    : >"$STATE/codesign.log"
    : >"$STATE/calls.log"
    # Loaded labels are files in loaded/. A bootstrap reads the label from the plist it's given. With a
    # number in bootout-lag, a label that's booted out still reads as loaded for that many more print or
    # bootstrap calls, the way launchd can take a few seconds after bootout returns.
    cat >"$STUBS/launchctl" <<EOF
#!/bin/bash
state="$STATE"
echo "\$*" >>"\$state/launchctl.log"
echo "launchctl \$*" >>"\$state/calls.log"
# True while the label's lag lasts, and uses one call of it.
lagging() {
    [ -s "\$state/lag-\$1" ] || return 1
    local left=\$((\$(cat "\$state/lag-\$1") - 1))
    if [ "\$left" -gt 0 ]; then echo "\$left" >"\$state/lag-\$1"; else rm -f "\$state/lag-\$1"; fi
}
case "\$1" in
    print) lagging "\${2##*/}" || [ -e "\$state/loaded/\${2##*/}" ] ;;
    bootout)
        [ -e "\$state/loaded/\${2##*/}" ] || exit 3
        rm -f "\$state/loaded/\${2##*/}"
        if [ -s "\$state/bootout-lag" ]; then cp "\$state/bootout-lag" "\$state/lag-\${2##*/}"; fi
        ;;
    bootstrap)
        label="\$(/usr/bin/plutil -extract Label raw -o - "\$3" 2>/dev/null)" || exit 5
        ! lagging "\$label" || exit 5
        [ -n "\$label" ] && [ ! -e "\$state/loaded/\$label" ] || exit 5
        touch "\$state/loaded/\$label"
        ;;
    *) exit 64 ;;
esac
EOF
    # A process runs while running/<name> exists. A restore runs for as many checks as the number in the
    # restoring file, and there's none without it.
    cat >"$STUBS/pgrep" <<EOF
#!/bin/bash
state="$STATE"
echo "\$*" >>"\$state/pgrep.log"
echo "pgrep \$*" >>"\$state/calls.log"
case "\$1" in
    -x) [ -e "\$state/running/\$2" ] ;;
    -f)
        [ -s "\$state/restoring" ] || exit 1
        left=\$((\$(cat "\$state/restoring") - 1))
        if [ "\$left" -gt 0 ]; then echo "\$left" >"\$state/restoring"; else rm -f "\$state/restoring"; fi
        ;;
    *) exit 1 ;;
esac
EOF
    cat >"$STUBS/codesign" <<EOF
#!/bin/bash
echo "\$*" >>"$STATE/codesign.log"
EOF
    # The real plutil only reads, so the stub records the call and lets it check the plist.
    cat >"$STUBS/plutil" <<EOF
#!/bin/bash
echo "\$*" >>"$STATE/plutil.log"
exec /usr/bin/plutil "\$@"
EOF
    chmod +x "$STUBS/launchctl" "$STUBS/pgrep" "$STUBS/codesign" "$STUBS/plutil"

    # Nothing may run unless every system command install.sh calls is a stub, and HOME is fake.
    local tool
    for tool in launchctl pgrep codesign plutil; do
        [ "$(PATH="$STUBS:$PATH" command -v "$tool")" = "$STUBS/$tool" ] ||
            fail "the $tool stub isn't first on PATH, so nothing was run"
    done
    case "$HOME_DIR" in "$TOP"/*) ;; *) fail "the fake home isn't in the temp directory" ;; esac
}

# make_world <name>: the built Porch Light, with nothing installed yet.
make_world() {
    use_world "$1"
    mkdir -p "$ROOT/Applications" "$HOME_DIR"
    make_stubs
    make_app "$BUILT" "$MARK"
}

# run_script <script> <arguments...>: in the world, as a test. Sets OUT and CODE.
run_script() {
    LAST_RUN="$(basename "$1") ${*:2}"
    OUT="$(
        cd "$W" &&
            env HOME="$HOME_DIR" PATH="$STUBS:$PATH" AD_NO_INSTALL=1 \
                PL_INSTALL_ROOT="$ROOT" PL_BUILT_APP="$BUILT" bash "$@" 2>&1
    )"
    CODE=$?
}

app_is() {
    [ -f "$1/Contents/mark" ] && [ "$(cat "$1/Contents/mark")" = "$2" ]
}

loaded() {
    [ -e "$STATE/loaded/$1" ]
}

# happened_in_order <call...>: each call is a whole line of calls.log, after the one before it.
happened_in_order() {
    local after=0 call line
    for call in "$@"; do
        line="$(awk -v after="$after" -v want="$call" 'NR > after && $0 == want { print NR; exit }' "$STATE/calls.log")"
        [ -n "$line" ] || return 1
        after="$line"
    done
}

# run_guarded <script> <home> <path>: the script with an unknown argument, which nothing before the
# fake-system guard reads. A guard that works refuses first; a broken one stops at the argument.
run_guarded() {
    LAST_RUN="$(basename "$1") --bogus, HOME=$2"
    OUT="$(env HOME="$2" PATH="$3" AD_NO_INSTALL=1 PL_INSTALL_ROOT="$TOP/guard-root" \
        PL_BUILT_APP="$TOP/guard-root/PorchLight.app" bash "$1" --bogus 2>&1)"
    CODE=$?
}

DOMAIN="gui/$UID"
REAL_HOME="$(id -P | cut -d: -f9)"

echo "install-test: (a) a first install with the guardian and the CLI link"
make_world a
run_script "$INSTALL" --guardian --link-cli
check "install exits 0" [ "$CODE" = 0 ]
check "it checked for a restore" has_line "$STATE/pgrep.log" "-f porchlight-guardian restore"
check "it asked nothing of an app that isn't running" [ ! -s "$STATE/cli.log" ]
check "Porch Light is installed from the build" app_is "$INSTALLED" "$MARK"
check "it said it installed Porch Light" said "install.sh: installed $INSTALLED"
check "the guardian was bootstrapped" has_line "$STATE/launchctl.log" "bootstrap $DOMAIN $AGENTS/$LABEL.plist"
check "the guardian is loaded" loaded "$LABEL"
check "it said the guardian started" said "install.sh: guardian started"
check "the plist logs to the Porch Light folder" \
    [ "$(/usr/bin/plutil -extract StandardOutPath raw -o - "$AGENTS/$LABEL.plist")" = "$HOME_DIR/Library/Logs/PorchLight/guardian.log" ]
check "the CLI link points into the installed app" \
    [ "$(readlink "$HOME_DIR/.local/bin/porchlight")" = "$INSTALLED/Contents/Helpers/porchlight" ]

echo "install-test: (b) a live session stops the install, and --end-session ends it"
make_world b
run_script "$INSTALL" --guardian
check "the first install exits 0" [ "$CODE" = 0 ]
touch "$STATE/running/PorchLight"
echo "state=active client=parsec displayID=9 lookslike=1728x1080" >"$STATE/session"
: >"$STATE/launchctl.log"
: >"$STATE/cli.log"
world_snapshot >"$W/world.before"
run_script "$INSTALL" --guardian
check "install fails" [ "$CODE" = 1 ]
check "it says a session is live, and how to end it" \
    said "a session is live in Porch Light; end it first with: porchlight session end -force"
check "it asked the running app for its session" has_line "$STATE/cli.log" "session status --no-launch --timeout=15"
check "it didn't end the session" eval '! grep -q "session end" "$STATE/cli.log"'
check "it didn't quit Porch Light" [ -e "$STATE/running/PorchLight" ]
check "it called no launchctl bootout or bootstrap" eval '! grep -qE "^boot(out|strap) " "$STATE/launchctl.log"'
check "nothing moved or appeared" eval 'world_snapshot | cmp -s - "$W/world.before"'
: >"$STATE/calls.log"
run_script "$INSTALL" --guardian --end-session
check "install with --end-session exits 0" [ "$CODE" = 0 ]
check "it said it was ending the session" said "install.sh: ending the live session in Porch Light"
check "it ended the session, then quit Porch Light" happened_in_order \
    "cli session end -force -reason=install --no-launch --timeout=60" "cli quit --no-launch --timeout=5"
check "it said it was quitting Porch Light" said "install.sh: quitting Porch Light"
check "Porch Light stopped running" [ ! -e "$STATE/running/PorchLight" ]
check "Porch Light is installed" app_is "$INSTALLED" "$MARK"
check "the guardian is loaded" loaded "$LABEL"

echo "install-test: (c) a reinstall"
make_world c
run_script "$INSTALL" --guardian
check "the first install exits 0" [ "$CODE" = 0 ]
echo "the installed copy" >"$INSTALLED/Contents/mark"
: >"$STATE/launchctl.log"
run_script "$INSTALL"
check "a reinstall without --guardian exits 0" [ "$CODE" = 0 ]
check "the installed copy is replaced by the build" app_is "$INSTALLED" "$MARK"
check "it leaves the loaded guardian alone" eval '! grep -qE "^boot(out|strap) " "$STATE/launchctl.log"'
check "the guardian is still loaded" loaded "$LABEL"
check "it says to run it again with --guardian" \
    said "install.sh: the guardian is still running the old binary. Run this again with --guardian to restart it."
# launchd takes a moment to finish the bootout.
echo 2 >"$STATE/bootout-lag"
: >"$STATE/calls.log"
run_script "$INSTALL" --guardian
check "a reinstall with --guardian exits 0" [ "$CODE" = 0 ]
check "it kept asking until the guardian was gone, then started it again" happened_in_order \
    "launchctl bootout $DOMAIN/$LABEL" "launchctl print $DOMAIN/$LABEL" "launchctl print $DOMAIN/$LABEL" \
    "launchctl print $DOMAIN/$LABEL" "launchctl bootstrap $DOMAIN $AGENTS/$LABEL.plist"
check "the guardian is loaded again" loaded "$LABEL"
check "it said the guardian started" said "install.sh: guardian started"

echo "install-test: (d) the fake-system guard refuses the real home and the real launchctl"
use_world d
mkdir -p "$W/home"
make_stubs
ln -s "$REAL_HOME" "$W/real-home-link"
for home in "$REAL_HOME" "$REAL_HOME/." "$W/real-home-link"; do
    run_guarded "$INSTALL" "$home" "$STUBS:$PATH"
    check "install.sh refuses HOME=$home" eval '[ "$CODE" = 1 ] && said "needs HOME set to a fake home" && not_said "unknown argument"'
done
run_guarded "$INSTALL" "$W/home" "$PATH"
check "install.sh refuses the real launchctl" \
    eval '[ "$CODE" = 1 ] && said "needs a launchctl stub" && not_said "unknown argument"'
run_guarded "$INSTALL" "$W/home" "$STUBS:$PATH"
check "install.sh gets past the guard with a fake home and stubs" said "unknown argument: --bogus"

echo "install-test: PASS, $CHECKS checks"

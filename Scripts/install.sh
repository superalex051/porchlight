#!/usr/bin/env bash
# Installs the built app to /Applications. Agents never run this: see AD_NO_INSTALL below.
#
#   --guardian      also install and start the LaunchAgent that rescues the displays if the app dies,
#                   restarting one that's running so it picks up the new binary
#   --link-cli      also link the CLI into ~/.local/bin
#   --end-session   force-end a live session first, which brings the monitors back
#
# A running copy is quit first. Without --end-session, a live session stops the install instead, because
# ending it could cut off whoever is connected. Nothing is replaced or stopped while a restore is running.
#
# For tests only: PL_INSTALL_ROOT goes in front of every /Applications path, and with it PL_BUILT_APP
# can name the built app. The test also sets HOME to a fake home, and puts stubs for launchctl, pgrep,
# codesign and plutil first on PATH.
set -euo pipefail

INSTALL_ROOT="${PL_INSTALL_ROOT:-}"

# A fake root can't reach the real install, so it's allowed under AD_NO_INSTALL.
if [ -n "${AD_NO_INSTALL:-}" ] && [ -z "$INSTALL_ROOT" ]; then
    echo "install.sh: refusing, because AD_NO_INSTALL is set." >&2
    exit 1
fi

# A checklist runs this from a `zsh -s` block. Anything here that read stdin would eat its next lines.
exec </dev/null

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail() {
    echo "install.sh: $1" >&2
    exit 1
}

# True if both paths are the same folder, however they're spelled. Two that can't be read count as the
# same, so the guard below refuses rather than guesses.
same_folder() {
    [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$2" 2>/dev/null && pwd -P)" ]
}

# With the real home or the real launchctl, a fake root would still change the real LaunchAgents.
if [ -n "$INSTALL_ROOT" ]; then
    ! same_folder "$HOME" "$(id -P | cut -d: -f9)" \
        || fail "PL_INSTALL_ROOT is for tests, and needs HOME set to a fake home."
    [ "$(command -v launchctl)" != /bin/launchctl ] \
        || fail "PL_INSTALL_ROOT is for tests, and needs a launchctl stub first on PATH."
fi

BUILT="build/PorchLight.app"
if [ -n "$INSTALL_ROOT" ] && [ -n "${PL_BUILT_APP:-}" ]; then
    BUILT="$PL_BUILT_APP"
fi
CLI="$BUILT/Contents/Helpers/porchlight"
INSTALLED="$INSTALL_ROOT/Applications/PorchLight.app"
LABEL="com.alexluncan.PorchLight.guardian"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGS="$HOME/Library/Logs/PorchLight"
LINK="$HOME/.local/bin/porchlight"

# Longer than the app's 10 second limit on ending a session.
QUIT_WAIT_SECONDS=30
# Longer than a restore takes with all its tries.
RESTORE_WAIT_SECONDS=200
# launchd can still list a job for a few seconds after `launchctl bootout` returns.
BOOTOUT_WAIT_SECONDS=10

install_guardian=false
link_cli=false
end_session=false
for argument in "$@"; do
    case "$argument" in
        --guardian) install_guardian=true ;;
        --link-cli) link_cli=true ;;
        --end-session) end_session=true ;;
        *) fail "unknown argument: $argument. It takes --guardian, --link-cli and --end-session." ;;
    esac
done

[ -d "$BUILT" ] || fail "$BUILT is missing. Run Scripts/build.sh."
codesign --verify --deep --strict "$BUILT" || fail "$BUILT doesn't verify, so nothing was installed."

is_running() {
    pgrep -x PorchLight >/dev/null 2>&1
}

# The guardian's restore helper is turning the monitors back on.
restore_running() {
    pgrep -f 'porchlight-guardian restore' >/dev/null 2>&1
}

# Neither app nor guardian may be replaced or stopped under a restore. $1 says what was left undone if it
# never finishes.
wait_for_restore() {
    local waited=0
    while restore_running; do
        if [ "$waited" -eq 0 ]; then
            echo "install.sh: waiting for a display restore to finish"
        fi
        [ "$waited" -lt "$RESTORE_WAIT_SECONDS" ] \
            || fail "a display restore was still running after $RESTORE_WAIT_SECONDS seconds, so $1. Try again once it's done."
        sleep 1
        waited=$((waited + 1))
    done
}

session_status() {
    "$CLI" session status --no-launch --timeout=15 2>&1 || true
}

# Quitting ends any session, and whoever is connected to it would lose their screen. So a live one stops
# the install, unless --end-session asked to end it here first.
check_no_live_session() {
    local status
    is_running || return 0
    status="$(session_status)"
    case "$status" in
        state=idle) return 0 ;;
        *"app not running"*) return 0 ;;
        state=*) ;;
        *) fail "Porch Light didn't answer session status ($status), so nothing was installed." ;;
    esac
    $end_session \
        || fail "a session is live in Porch Light; end it first with: porchlight session end -force (or run this again with --end-session)"
    echo "install.sh: ending the live session in Porch Light"
    "$CLI" session end -force -reason=install --no-launch --timeout=60 \
        || fail "the session didn't end, so nothing was installed."
    status="$(session_status)"
    [ "$status" = "state=idle" ] || fail "the session still isn't idle ($status), so nothing was installed."
}

quit_running_copy() {
    is_running || return 0
    echo "install.sh: quitting Porch Light"
    # Whether it answers doesn't matter, because it can exit before it does. The wait below decides.
    "$CLI" quit --no-launch --timeout=5 >/dev/null 2>&1 || true
    local waited=0
    while is_running; do
        [ "$waited" -lt "$QUIT_WAIT_SECONDS" ] \
            || fail "Porch Light didn't quit, so nothing was installed. Quit it from its menu and try again."
        sleep 1
        waited=$((waited + 1))
    done
}

# True once launchd no longer lists the guardian, asked twice a second for BOOTOUT_WAIT_SECONDS.
wait_for_bootout() {
    local tries
    for ((tries = 0; tries < BOOTOUT_WAIT_SECONDS * 2; tries++)); do
        launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 1
}

# Through a new folder that's then swapped in, for two reasons. A failed copy leaves the old app whole.
# And macOS can kill a signed binary that was overwritten in place, so each file has to be a new one.
copy_app() {
    local new="$INSTALLED.new" old="$INSTALLED.old"
    rm -rf "$new" "$old"
    ditto "$BUILT" "$new"
    if [ -e "$INSTALLED" ]; then
        mv "$INSTALLED" "$old"
    fi
    mv "$new" "$INSTALLED"
    rm -rf "$old"
    echo "install.sh: installed $INSTALLED"
}

# launchd can refuse a job whose log directory is missing. It can also fail a bootstrap that comes right
# after a bootout, while the old job is still going away, so that gets a few tries.
start_guardian() {
    local domain="gui/$UID"
    mkdir -p "$LOGS" "$(dirname "$AGENT")"
    local home_for_sed
    home_for_sed="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
    sed "s|__HOME__|$home_for_sed|g" "Config/$LABEL.plist" > "$AGENT"
    plutil -lint -s "$AGENT" || fail "the LaunchAgent plist isn't valid: $AGENT"

    if launchctl print "$domain/$LABEL" >/dev/null 2>&1; then
        wait_for_restore "the guardian was left running the old binary"
        launchctl bootout "$domain/$LABEL" || true
        # The bootstrap below gets its own tries, so a slow bootout isn't a failure here.
        wait_for_bootout || true
    fi
    local attempt error=""
    for attempt in 1 2 3 4 5; do
        if error="$(launchctl bootstrap "$domain" "$AGENT" 2>&1)"; then
            echo "install.sh: guardian started"
            return 0
        fi
        sleep 1
    done
    fail "launchctl bootstrap failed for $AGENT: $error"
}

wait_for_restore "nothing was installed"
check_no_live_session
quit_running_copy
copy_app

if $install_guardian; then
    start_guardian
elif launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1; then
    echo "install.sh: the guardian is still running the old binary. Run this again with --guardian to restart it."
fi

if $link_cli; then
    # From the installed copy, because the CLI finds its helper as a sibling of the resolved path.
    mkdir -p "$(dirname "$LINK")"
    ln -sf "$INSTALLED/Contents/Helpers/porchlight" "$LINK"
    echo "install.sh: linked $LINK"
fi

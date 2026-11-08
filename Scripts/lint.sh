#!/usr/bin/env bash
# Repo rules that the compiler can't enforce. Read only. Only files git tracks are scanned,
# so untracked notes on disk never count.
# Exit 0: clean. Exit 1: violations, all listed. Exit 2: a check could not run.
set -uo pipefail

# Match raw bytes, so the dash patterns work in any locale.
export LC_ALL=C

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

ALLOWLIST="Scripts/lint-allowlist.txt"

# Spelled as bytes so this file passes its own dash rule.
EM_DASH=$'\xe2\x80\x94'
EN_DASH=$'\xe2\x80\x93'

MATCHES=""
FILES=()
violations=0

# Sets FILES to the tracked files under the given paths that are on disk, so a tracked
# file deleted but not yet staged is skipped. A git error stops the lint.
tracked_files() {
    local list file
    list="$(git ls-files -z -- "$@" | tr '\0' '\n')" || {
        echo "lint: could not list the tracked files in $*" >&2
        exit 2
    }
    FILES=()
    while IFS= read -r file; do
        [ -f "$file" ] && FILES+=("$file")
    done <<< "$list"
}

# Sets MATCHES to "path:line:text" lines from the tracked files under the given paths.
# A grep error stops the lint, so a check that could not run never reads as clean.
find_matches() {
    local pattern="$1" status=0
    shift
    MATCHES=""
    tracked_files "$@"
    [ "${#FILES[@]}" -gt 0 ] || return 0
    MATCHES="$(grep -HInE -e "$pattern" -- "${FILES[@]}")" || status=$?
    if [ "$status" -gt 1 ]; then
        echo "lint: could not scan $* (grep exit $status)" >&2
        exit 2
    fi
}

report() {
    echo "lint: $1: $2"
    violations=$((violations + 1))
}

# True if $1 is one of the other arguments, or inside one of them.
is_within() {
    local path="$1" allowed
    shift
    for allowed in "$@"; do
        [ "$path" = "$allowed" ] && return 0
        case "$path" in "$allowed"/*) return 0 ;; esac
    done
    return 1
}

# True if the allowlist has a justified entry for file $1 and token $2.
is_allowlisted() {
    awk -F'[[:space:]]*[|][[:space:]]*' -v path="$1" -v token="$2" '
        /^[[:space:]]*#/ { next }
        $1 == path && $2 == token && $3 != "" { found = 1 }
        END { exit !found }
    ' "$ALLOWLIST"
}

# check_everywhere <rule> <pattern> <roots...>: any match is a violation.
check_everywhere() {
    local rule="$1" pattern="$2" hit
    shift 2
    find_matches "$pattern" "$@"
    while IFS= read -r hit; do
        [ -n "$hit" ] && report "$rule" "$hit"
    done <<< "$MATCHES"
}

# check_allowlisted <token> <pattern>: a match needs an allowlist entry.
check_allowlisted() {
    local token="$1" pattern="$2" hit
    find_matches "$pattern" Sources Tests App
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        is_allowlisted "${hit%%:*}" "$token" || report "$token needs an entry in $ALLOWLIST" "$hit"
    done <<< "$MATCHES"
}

# check_confined <rule> <pattern> <allowed paths...>: a match outside them is a violation.
# This script is skipped because it has to name the symbols.
check_confined() {
    local rule="$1" pattern="$2" hit
    shift 2
    find_matches "$pattern" Sources Tests App Scripts
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        is_within "${hit%%:*}" Scripts/lint.sh "$@" || report "$rule" "$hit"
    done <<< "$MATCHES"
}

check_everywhere "em or en dash" "$EM_DASH|$EN_DASH" Sources Tests App Scripts docs README.md

check_allowlisted "@unchecked Sendable" '@unchecked[[:space:]]+Sendable'
check_allowlisted "nonisolated(unsafe)" 'nonisolated[[:space:]]*\([[:space:]]*unsafe[[:space:]]*\)'

check_confined "CGSConfigureDisplayEnabled belongs in ADSPI or LiveDisplayBackend" \
    'CGSConfigureDisplayEnabled' \
    Sources/ADDisplays/LiveDisplayBackend.swift \
    Sources/ADSPI \
    Sources/CPrivateSPI

check_confined "CGCompleteDisplayConfiguration belongs in LiveDisplayBackend" \
    'CGCompleteDisplayConfiguration' \
    Sources/ADDisplays/LiveDisplayBackend.swift \
    Sources/CPrivateSPI

# ADSPI has no mutation guard, so its wrappers are confined the same way as the SPI they wrap.
check_confined "DisplayEnable.configure belongs in LiveDisplayBackend" \
    'DisplayEnable\.configure' \
    Sources/ADSPI \
    Sources/ADDisplays/LiveDisplayBackend.swift

check_confined "virtual display SPI calls belong in ADSPI or LiveVirtualScreenProvider" \
    'applySettings|CGVirtualDisplay(\.init)?\(' \
    Sources/ADSPI \
    Sources/CPrivateSPI \
    Sources/ADVirtualScreens/LiveVirtualScreenProvider.swift

check_confined "VirtualDisplayHandle belongs in LiveVirtualScreenProvider" \
    'VirtualDisplayHandle' \
    Sources/ADSPI \
    Sources/ADVirtualScreens/LiveVirtualScreenProvider.swift

check_everywhere "hard-coded desk monitor UUID" '40[Aa]936[Aa]8|0[Aa]4[Ff][Aa]257' Sources

# AppKit spins a nested event loop inside `terminate`, and from inside a Swift task that loop can't run the
# main actor jobs the quit waits for, so the app hangs. Only Termination.request() calls it, from a plain
# run loop callback. App only, because a CLI stopping a child process is a different `terminate`.
find_matches '(^|[^[:alnum:]_])terminate[[:space:]]*\(' App
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    is_within "${hit%%:*}" App/Termination.swift \
        || report "terminate belongs in App/Termination.swift, called through Termination.request()" "$hit"
done <<< "$MATCHES"

if [ "$violations" -gt 0 ]; then
    echo "lint: FAILED with $violations violation(s)"
    exit 1
fi
echo "lint: OK"

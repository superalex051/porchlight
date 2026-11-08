#!/usr/bin/env bash
# Runs every end-to-end scenario in Scripts/e2e, in order, each on its own simulated copy of this Mac.
# Nothing here changes a real display: the scenarios run `addevhost` in a dry run on throwaway paths,
# with the CLI and `porchlight-guardian` from `.build`, and read the real displays only to compare
# `displayplacer list` before and after. This does the same for the whole suite.
#
# Arguments, if any, pick scenarios by number: `run-all.sh 01 05`.
# Exit 0: every scenario passed and the real displays read the same. 1: something failed. 2: it couldn't run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

if [ -n "${AD_HIL+set}" ]; then
    echo "run-all: AD_HIL is set. These scenarios are dry runs only, so unset it." >&2
    exit 2
fi
command -v displayplacer >/dev/null || { echo "run-all: displayplacer is needed" >&2; exit 2; }

WORK="$(mktemp -d -t ad-e2e-all)" || exit 2
trap 'rm -rf "$WORK"' EXIT

echo "run-all: building"
for product in addevhost porchlight porchlight-guardian; do
    if ! swift build --product "$product" >"$WORK/build.log" 2>&1; then
        tail -30 "$WORK/build.log"
        echo "run-all: swift build --product $product failed" >&2
        exit 2
    fi
done
export E2E_BUILT=1

displayplacer list >"$WORK/real-before.txt" 2>&1 || { echo "run-all: displayplacer list failed" >&2; exit 2; }

scenarios=()
for script in Scripts/e2e/[0-9][0-9]-*.sh; do
    if [ "$#" -gt 0 ]; then
        number="$(basename "$script" | cut -c1-2)"
        wanted=""
        for pick in "$@"; do [ "$pick" = "$number" ] && wanted=yes; done
        [ -n "$wanted" ] || continue
    fi
    scenarios+=("$script")
done
[ "${#scenarios[@]}" -gt 0 ] || { echo "run-all: no scenario matches $*" >&2; exit 2; }

started="$(date +%s)"
failed=0
: >"$WORK/results"
for script in "${scenarios[@]}"; do
    "$script" 2>&1 | tee "$WORK/scenario.out"
    status="${PIPESTATUS[0]}"
    verdict="$(grep -E '^(PASS|FAIL) ' "$WORK/scenario.out" | tail -1)"
    if [ "$status" -ne 0 ]; then
        failed=$((failed + 1))
        [ -n "$verdict" ] || verdict="FAIL $(basename "$script" .sh): exited $status with no verdict"
    fi
    echo "$verdict" >>"$WORK/results"
    echo
done

displayplacer list >"$WORK/real-after.txt" 2>&1
real_same=yes
cmp -s "$WORK/real-before.txt" "$WORK/real-after.txt" || real_same=""

echo "run-all: results"
cut -c1-160 "$WORK/results" | sed 's/^/  /'
echo "run-all: ${#scenarios[@]} scenarios, $failed failed, $(($(date +%s) - started)) s"
if [ -n "$real_same" ]; then
    echo "run-all: displayplacer list read the same before and after the suite"
else
    echo "run-all: displayplacer list changed during the suite. Nothing here should do that, though a person, an attended run or a display going to sleep can:"
    diff "$WORK/real-before.txt" "$WORK/real-after.txt" | grep -v '^[<>]   mode ' | head -20
    failed=$((failed + 1))
fi
[ "$failed" -eq 0 ] || exit 1

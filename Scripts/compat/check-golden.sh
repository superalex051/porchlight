#!/usr/bin/env bash
# Replays the golden corpus's read-only rows against the installed CLI and compares stdout, stderr
# and the exit code byte for byte. Only a row whose one operation is `get` runs. `set`, `create`,
# `discard`, `session`, `rescue` and anything unrecognized are refused and never reach the CLI.
#
# Every call passes --no-launch, so this never starts the app. Start it first. The rows describe the
# normal desk, so run this with no session active.
#
# AD_CLI picks another CLI. AD_SOCKET_PATH and AD_STATE_DIR reach it unchanged, for a dry-run host.
#
# Exit 0: every replayed row matched. Exit 1: a row differs. Exit 2: the replay could not run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

CORPUS="Tests/Fixtures/Golden/cli.json"
CLI="${AD_CLI:-/Applications/PorchLight.app/Contents/Helpers/porchlight}"

# What the corpus's <LG> and <M34> stand for, the same lookup as Tests/ADEngineTests/GoldenResultTests.swift.
LG_NAME="27GL850"
M34_NAME="M34WQ"

fail_to_run() {
    echo "check-golden: $1" >&2
    exit 2
}

command -v jq >/dev/null || fail_to_run "jq is missing"
[ -f "$CORPUS" ] || fail_to_run "no corpus at $CORPUS"
[ -x "$CLI" ] || fail_to_run "no CLI at $CLI"

WORK="$(mktemp -d)" || fail_to_run "cannot make a temp directory"
trap 'rm -rf "$WORK"' EXIT

"$CLI" --no-launch --json get -identifiers >"$WORK/identifiers" 2>"$WORK/identifiers.err" ||
    fail_to_run "get -identifiers failed, is the app running? $(cat "$WORK/identifiers" "$WORK/identifiers.err")"

uuid_named() {
    jq -r --arg name "$1" '.json[] | select(.productName == $name) | .UUID' "$WORK/identifiers"
}
LG_UUID="$(uuid_named "$LG_NAME")"
M34_UUID="$(uuid_named "$M34_NAME")"
[ -n "$LG_UUID" ] || fail_to_run "no display named $LG_NAME in get -identifiers"
[ -n "$M34_UUID" ] || fail_to_run "no display named $M34_NAME in get -identifiers"

# Empty if this row may run, otherwise why not. Bare words are operations, wherever they sit in argv,
# so all of them are checked, and anything but one `get` is refused.
refusal_of() {
    local word operations=()
    for word in "$@"; do
        case "$word" in
            -*) ;;
            *) operations+=("$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')") ;;
        esac
    done
    for word in ${operations[@]+"${operations[@]}"}; do
        case "$word" in
            set | create | discard | session | rescue)
                echo "$word rows do not run here"
                return
                ;;
        esac
    done
    if [ "${#operations[@]}" -ne 1 ] || [ "${operations[0]}" != "get" ]; then
        echo "not a plain get"
    fi
}

row_count="$(jq 'length' "$CORPUS")" || fail_to_run "cannot read $CORPUS"
replayed=0
refused=0
mismatched=0

for ((row = 0; row < row_count; row++)); do
    argv=()
    while IFS= read -r -d '' word; do
        argv+=("$word")
    done < <(jq -j --argjson row "$row" '.[$row].argv[] | ., "\u0000"' "$CORPUS")
    [ "${#argv[@]}" -gt 0 ] || fail_to_run "row $row has no argv"

    why="$(refusal_of "${argv[@]}")"
    if [ -n "$why" ]; then
        refused=$((refused + 1))
        echo "refused: ${argv[*]} ($why)"
        continue
    fi

    filled=()
    for word in "${argv[@]}"; do
        word="${word//<LG>/$LG_UUID}"
        word="${word//<M34>/$M34_UUID}"
        filled+=("$word")
    done

    jq -j --argjson row "$row" '.[$row].stdout' "$CORPUS" >"$WORK/want.stdout"
    jq -j --argjson row "$row" '.[$row].stderr' "$CORPUS" >"$WORK/want.stderr"
    want_exit="$(jq --argjson row "$row" '.[$row].exit' "$CORPUS")"

    "$CLI" --no-launch "${filled[@]}" >"$WORK/got.stdout" 2>"$WORK/got.stderr"
    got_exit=$?

    replayed=$((replayed + 1))
    if [ "$got_exit" = "$want_exit" ] &&
        cmp -s "$WORK/want.stdout" "$WORK/got.stdout" &&
        cmp -s "$WORK/want.stderr" "$WORK/got.stderr"; then
        echo "ok: ${argv[*]}"
    else
        mismatched=$((mismatched + 1))
        echo "MISMATCH: ${argv[*]}"
        echo "  exit:   want $want_exit, got $got_exit"
        echo "  stdout: want [$(cat "$WORK/want.stdout")], got [$(cat "$WORK/got.stdout")]"
        echo "  stderr: want [$(cat "$WORK/want.stderr")], got [$(cat "$WORK/got.stderr")]"
    fi
done

echo "check-golden: $replayed replayed, $refused refused, $mismatched mismatched"
# A corpus with no read-only rows proves nothing, so it must not read as a pass.
[ "$replayed" -gt 0 ] || fail_to_run "nothing was replayed"
[ "$mismatched" -eq 0 ] || exit 1

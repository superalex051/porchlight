#!/usr/bin/env bash
# Runs the unit tests, then the install test. Arguments go to `swift test`.
# Hardware tests only run with a person present, so this refuses to run with AD_HIL set.
set -euo pipefail

if [ -n "${AD_HIL+set}" ]; then
    echo "test.sh: AD_HIL is set. Hardware tests are attended only, so unset it to run the unit tests." >&2
    exit 1
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift test "$@"
# In a fake root and home, with stubs for launchctl and the rest, so it never touches this Mac.
Scripts/tests/install-test.sh

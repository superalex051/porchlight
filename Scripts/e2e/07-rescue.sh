#!/usr/bin/env bash
# Scenario 7: `rescue` with the host up, and with it down, where the CLI runs
# `porchlight-guardian restore` itself. Under AD_DRY_RUN=1 that helper is a dry run too. The CLI
# throws away the helper's output, so one run goes through a small shim that keeps the helper's
# stderr, to see its plan. Also desk-mode's third branch: end failed, rescuing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "07-rescue"

DRY_STEPS='^dry run: (enable|disable|commit|addVirtual|removeVirtual|setVirtualMode|gone) '

start_host

# Host up, no session: a quiet success that reconnects from the registry, which has nothing off. It
# also tries every other display that's off, and a display the copy saw off at the start can't come on.
cli rescue
expect_ok "rescue with no session"
expect_out "" "rescue with no session"
NO_SESSION_SECS="$SECS"
grep -q "Rescue with no session, so this reconnects from the registry" "$AD_STATE_DIR/session.log" ||
    fail "the host didn't log a rescue with no session"
read_plan
check_plan_words "$PLAN"
changed="$(grep -vE '^enable [0-9]+ failed ' <<<"$PLAN" || true)"
[ -z "$changed" ] || fail "a rescue with nothing off changed something: $(tr '\n' ';' <<<"$changed")"
TRIED="$(sed -n 's/^enable \([0-9]*\) failed .*/\1/p' <<<"$PLAN" | sort -u | tr '\n' ' ')"
note "host up, no session: rescue took $NO_SESSION_SECS s, changed nothing${TRIED:+, and tried display(s) ${TRIED}that the copy saw off}"

# Host up, session active: the host force-ends it.
cli session start -client=parsec "-ownerpid=$$"
expect_ok "session start"
OFF="$(field off "$OUT")"
[ -n "$OFF" ] || fail "the session turned nothing off"
cli rescue
expect_ok "rescue during a session"
expect_out "" "rescue during a session"
cli session status
expect_out "state=idle" "status after the rescue"
[ ! -e "$(ledger)" ] || fail "the ledger is still there after the rescue"
grep -q "Ending the session: rescue" "$AD_STATE_DIR/session.log" || fail "the host didn't log a rescue end"
read_plan
check_sessions "$PLAN" 1 "$OFF"
note "host up: rescue ended the session and brought back $OFF"

# Host down mid-session. The CLI finds `porchlight-guardian` beside its real path, through the link.
cli session start -client=parsec "-ownerpid=$$"
expect_ok "the second session's start"
crash_host
cp "$(ledger)" "$WORK/ledger-at-crash.json"
saved_helper="$AD_GUARDIAN_PATH"
unset AD_GUARDIAN_PATH
cli rescue
expect_ok "rescue with the host down, by the helper beside the CLI"
expect_out "" "rescue with the host down"
export AD_GUARDIAN_PATH="$saved_helper"
cmp -s "$(ledger)" "$WORK/ledger-at-crash.json" || fail "a dry-run helper changed the ledger"
note "host down: rescue ran the helper found through the link, in $SECS s"

# The same through a shim that keeps the helper's stderr, to see what it did.
cat >"$WORK/bin/porchlight-guardian-shim" <<EOF
#!/bin/sh
echo "argv: \$*" >>"$WORK/helper.log"
exec "$GUARDIAN" "\$@" 2>>"$WORK/helper.log"
EOF
chmod +x "$WORK/bin/porchlight-guardian-shim"
export AD_GUARDIAN_PATH="$WORK/bin/porchlight-guardian-shim"
cli rescue
expect_ok "rescue with the host down, through the shim"
grep -qx "argv: restore" "$WORK/helper.log" || fail "the CLI didn't run the helper as 'restore': $(head -1 "$WORK/helper.log")"
grep -qx "dry run: restore starting" "$WORK/helper.log" || fail "the helper didn't run as a dry run"
grep -qx "restore succeeded" "$WORK/helper.log" || fail "the helper didn't succeed: $(cat "$WORK/helper.log")"
HELPER_PLAN="$(grep -E "$DRY_STEPS" "$WORK/helper.log" | sed 's/^dry run: //')"
check_plan_words "$HELPER_PLAN"
for id in ${OFF//,/ }; do
    grep -qx "enable $id" <<<"$HELPER_PLAN" || fail "the helper's plan never brings back display $id: [$HELPER_PLAN]"
done
note "the helper's plan: $(tr '\n' ';' <<<"$HELPER_PLAN")"

# desk-mode with the host down takes its third branch, and the rescue works.
sed "s|^AD=.*\$|AD=\"$CLI\"|" Scripts/parsec/desk-mode >"$WORK/bin/desk-mode"
chmod +x "$WORK/bin/desk-mode"
: >"$WORK/helper.log"
run_script "$WORK/bin/desk-mode"
expect_ok "desk-mode with the host down"
expect_out "desk-mode: end failed (Failed. app not running), rescuing" "desk-mode with the host down"
grep -qx "restore succeeded" "$WORK/helper.log" || fail "desk-mode's rescue didn't run the helper to success"

# No ledger and no host: the helper reconnects from the registry, and nothing is off.
rm -f "$(ledger)"
: >"$WORK/helper.log"
cli rescue
expect_ok "rescue with no host and no ledger"
grep -qx "restore succeeded" "$WORK/helper.log" || fail "the no-ledger helper didn't succeed: $(cat "$WORK/helper.log")"
changed="$(grep -E "$DRY_STEPS" "$WORK/helper.log" | grep -vE '^dry run: enable [0-9]+ failed ' || true)"
[ -z "$changed" ] || fail "with nothing off, the no-ledger helper changed something: $(tr '\n' ';' <<<"$changed")"

# A helper that isn't there is named, for someone remote with dark monitors.
export AD_GUARDIAN_PATH="$WORK/bin/no-such-helper"
cli rescue
expect_code 1 "rescue with no helper"
expect_err "Failed. app not running, and the restore helper is missing: $WORK/bin/no-such-helper" "rescue with no helper"

e2e_pass "host up: rescue with no session changed nothing, during a session it ended it and brought back $OFF; host down: the CLI ran the dry-run helper found through the link, the helper's own plan brought back $OFF, desk-mode took its rescue branch, a no-ledger rescue changed nothing, and a missing helper was named"

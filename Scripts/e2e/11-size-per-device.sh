#!/usr/bin/env bash
# Scenario 11: size per device (a preset for each client address) and match client (a screen sized to
# what the Parsec client reported). The host reads a fixture Parsec log and config through
# AD_PARSEC_LOG and AD_PARSEC_CONFIG, in the real files' shapes, never ~/.parsec. Six starts with
# -preset=auto: with every setting off (MacBook 14), with the MacBook mapped to MacBook 14 120 Hz (120 Hz),
# from an address that's no client with matching off (MacBook 14), with only a connect from two minutes
# ago (MacBook 14), from a phone whose size Parsec saved at the connect (1500x804), and from the same phone
# with the size saved ten minutes earlier (1500x804, after a wait). Each start logs the rule that chose its
# size to session.log, just before the start's own line. The clients commands write clients.json, and
# every session turns the monitors off once and back once.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
e2e_begin "11-size-per-device"

PARSEC_LOG="$AD_PARSEC_LOG"
PARSEC_CONFIG="$AD_PARSEC_CONFIG"
SESSION_LOG="$AD_STATE_DIR/session.log"
AT=""
SETTINGS_OFF="autoSize=off
matchClient=off
clearOfNotch=on
phoneRoom=4/3"

# parsec_connect <address> <seconds ago>: a guest connecting to this Mac from that address, as Parsec
# writes it (the connect of 2026-11-06 15:56:37), in local time. Sets AT to the connect's time of day.
parsec_connect() {
    local address="$1" ago="$2" net at
    net="$(date -v-"$((ago + 4))"S "+%Y-%m-%d %H:%M:%S")"
    at="$(date -v-"$ago"S "+%Y-%m-%d %H:%M:%S")"
    AT="${at#* }"
    cat >>"$PARSEC_LOG" <<EOF
[I $net] STUN reply from ::ffff:35.169.37.243:3478
[D $net] net           = BUD|::ffff:$address|31938
[D $net] BUD AES_GCM   = 256
[D $net] vp_supported  = 1
[D $at] capture       = macos_capture
[I $at] guest01#1234567 connected.
[D $at] codec         = h265
[D $at] encode_x      = 2560
[D $at] encode_y      = 1440
EOF
}

parsec_disconnect() {
    local at
    at="$(date "+%Y-%m-%d %H:%M:%S")"
    cat >>"$PARSEC_LOG" <<EOF
[D $at] vp_supported  = 0
[I $at] guest01#1234567 disconnected.
EOF
}

# parsec_config <width> <height>: Parsec's config in the real file's shape, with made-up values except
# the client's size, saved now.
parsec_config() {
    cat >"$PARSEC_CONFIG" <<EOF
[
    "See https://parsec.app/config for documentation and example.",
    {
        "app_host": {
            "value": true
        },
        "host_name": {
            "value": "Fixture Mac"
        },
        "server_resolution_x": {
            "value": $1
        },
        "server_resolution_y": {
            "value": $2
        }
    }
]
EOF
    [ "$(jq -c '.[1].server_resolution_x.value' "$PARSEC_CONFIG")" = "$1" ] || fail "the fixture config isn't valid JSON"
}

# auto_start <context> <lookslike> <pixels> <hz> <expected session.log line>: a start with -preset=auto,
# at that size, that logs exactly that choice, followed by the start's own line.
auto_start() {
    local context="$1" lookslike="$2" pixels="$3" hz="$4" wanted="$5" logged
    cli session start -client=parsec -preset=auto "-ownerpid=$$"
    expect_ok "$context: session start"
    [[ "$OUT" == "state=active client=parsec "* ]] || fail "$context: the start says $OUT"
    [ "$(field lookslike "$OUT")" = "$lookslike" ] || fail "$context: lookslike=$(field lookslike "$OUT"), expected $lookslike"
    [ "$(field pixels "$OUT")" = "$pixels" ] || fail "$context: pixels=$(field pixels "$OUT"), expected $pixels"
    [ "$(field hz "$OUT")" = "$hz" ] || fail "$context: hz=$(field hz "$OUT"), expected $hz"
    [ -z "$OFF" ] || [ "$(field off "$OUT")" = "$OFF" ] || fail "$context: turned off $(field off "$OUT"), not $OFF"
    OFF="$(field off "$OUT")"
    logged="$(grep -A1 -F "Auto size: " "$SESSION_LOG" | tail -2)"
    grep -qF "$wanted" <<<"$(head -1 <<<"$logged")" || fail "$context: session.log says [$(head -1 <<<"$logged")], expected [$wanted]"
    grep -qF "Starting a session for parsec, $lookslike" <<<"$(tail -1 <<<"$logged")" ||
        fail "$context: the start's own line doesn't follow the choice: $(tail -1 <<<"$logged")"
}

end_session() {
    cli session end -client=parsec
    expect_ok "$1: session end"
    parsec_disconnect
}

OFF=""
start_host

cli clients list
expect_ok "clients list"
expect_out "autoSize=off
matchClient=on
clearOfNotch=on
phoneRoom=4/3" "clients list with no file"
[ ! -e "$AD_STATE_DIR/clients.json" ] || fail "reading the clients wrote clients.json"

# 1. Everything off, so the MacBook gets the default even before it's mapped.
cli clients match -off
expect_ok "clients match -off"
expect_out "" "clients match -off"
cli clients list
expect_out "$SETTINGS_OFF" "clients list after match -off"
parsec_connect 192.168.0.232 1
auto_start "everything off" 1728x1080 3456x2160 60 "Auto size: off, so the size is MacBook 14, the default"
end_session "everything off"

# 2. Mapped to the 120 Hz preset and turned on.
cli clients set -name=MacBook -address=::ffff:192.168.0.232 "-preset=MacBook 14 120 Hz"
expect_ok "clients set"
expect_out "" "clients set"
cli clients auto -on
expect_ok "clients auto -on"
cli clients list
expect_ok "clients list"
expect_out "autoSize=on
matchClient=off
clearOfNotch=on
phoneRoom=4/3
MacBook: address=192.168.0.232 preset=MacBook 14 120 Hz" "clients list after set"
[ "$(jq -c . "$AD_STATE_DIR/clients.json")" = '{"autoSize":true,"clearOfNotch":true,"clients":[{"match":{"address":"192.168.0.232"},"name":"MacBook","preset":"MacBook 14 120 Hz"}],"matchClient":false,"phoneRoom":"4/3"}' ] ||
    fail "clients.json is $(jq -c . "$AD_STATE_DIR/clients.json")"

parsec_connect 192.168.0.232 0
auto_start "the MacBook" 1728x1080 3456x2160 120 "Auto size: the Parsec connect at $AT came from 192.168.0.232, which is client MacBook, so the size is MacBook 14 120 Hz"
cli session resize -preset=auto
expect_code 1 "resize -preset=auto"
expect_err "Failed. -preset=auto is only for session start" "resize -preset=auto"
end_session "the MacBook"

# 3. A device that isn't a client, with matching off.
parsec_connect 192.168.0.10 0
auto_start "an unknown device" 1728x1080 3456x2160 60 "Auto size: 192.168.0.10, from the Parsec connect at $AT, isn't a client, so the size is MacBook 14, the default"
end_session "an unknown device"

# 4. Only an old connect: the MacBook connected two minutes ago, so it isn't this session's guest.
: >"$PARSEC_LOG"
parsec_connect 192.168.0.232 120
auto_start "an old connect" 1728x1080 3456x2160 60 "Auto size: no Parsec connect in the last 60 s, so the size is MacBook 14, the default"
end_session "an old connect"

# 5. Matching on, and a phone upright on cellular whose size Parsec saved at the connect: trimmed clear
#    of the notch to 2250x1206, then 4/3 of that, 3000x1608, HiDPI at half.
cli clients match -on
expect_ok "clients match -on"
parsec_connect 203.0.113.7 0
parsec_config 1206 2622
auto_start "a phone, size saved at the connect" 1500x804 3000x1608 60 "Auto size: 203.0.113.7, from the Parsec connect at $AT, isn't a client; the client reported 1206x2622, so the size is 1500x804 (clear of the notch, phone room 4/3)"
end_session "a phone, size saved at the connect"

# 6. The same phone again, and Parsec didn't save the size this time: the saved one is used, after a wait.
SAVED="$(($(date +%s) - 600))"
touch -t "$(date -r "$SAVED" "+%Y%m%d%H%M.%S")" "$PARSEC_CONFIG"
parsec_connect 203.0.113.7 0
# The log names the day too if the size was saved on another day, as it is just after midnight.
if [ "$(date -r "$SAVED" +%F)" = "$(date +%F)" ]; then
    SAVED_TIME="$(date -r "$SAVED" +%T)"
else
    SAVED_TIME="$(date -r "$SAVED" "+%F %T")"
fi
auto_start "a phone, size saved earlier" 1500x804 3000x1608 60 "Auto size: 203.0.113.7, from the Parsec connect at $AT, isn't a client; Parsec kept 1206x2622 from an earlier connect (saved at $SAVED_TIME), so the size is 1500x804 (clear of the notch, phone room 4/3)"
less_than 2.9 "$SECS" || fail "the start with a size saved earlier took $SECS s, so it didn't wait for a new one"
end_session "a phone, size saved earlier"

cli clients set -name=iPad -address=192.168.0.300 "-preset=MacBook 14"
expect_code 1 "clients set with a bad address"
expect_err "Failed. not an IP address: 192.168.0.300" "clients set with a bad address"
cli clients remove -name=macbook
expect_ok "clients remove"
cli clients list
expect_out "autoSize=on
matchClient=on
clearOfNotch=on
phoneRoom=4/3" "clients list after remove"

cli session status
expect_out "state=idle" "status at the end"
read_plan
check_sessions "$PLAN" 6 "$OFF"

stop_host
[ "$HOST_STATUS" = 0 ] || fail "the host exited with $HOST_STATUS"
e2e_pass "everything off, a mapped MacBook at 120 Hz, an unknown device, an old connect, and a phone's size saved at the connect and earlier each chose as logged; 6 sessions, monitors off once and back once each"

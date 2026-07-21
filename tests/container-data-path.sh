#!/bin/sh
set -eu

TARGET_PORT=19083
GATE_PORT=18443
MARKER=GTAGOD-E2E-OK
TARGET_PID=""
TEMP_ROOT=$(mktemp -d)

cleanup() {
    [ -n "$TARGET_PID" ] && kill "$TARGET_PID" 2>/dev/null || true
    [ -n "$TARGET_PID" ] && wait "$TARGET_PID" 2>/dev/null || true
    rm -rf "$TEMP_ROOT"
}
trap cleanup 0 1 2 15

# One-shot target behind GTACore. It half-closes its write side after the
# marker; the VLESS relay must still drain that response after client EOF.
printf '%s' "$MARKER" | nc -l 127.0.0.1 "$TARGET_PORT" > "$TEMP_ROOT/target-request" &
TARGET_PID=$!
sleep 1

# VLESS request:
# version=0, UUID=11111111-1111-4111-8111-111111111111, addons=empty,
# command=TCP, port=19083 (0x4a8b), address=127.0.0.1, payload=PING.
# A non-TLS first byte makes gtagate select default_upstream while preserving
# the complete prefetched request for GTACore.
printf '\000\021\021\021\021\021\021\101\021\201\021\021\021\021\021\021\021\000\001\112\213\001\177\000\000\001PING' \
    | nc -w 5 127.0.0.1 "$GATE_PORT" > "$TEMP_ROOT/client-response"

wait "$TARGET_PID"
TARGET_PID=""

[ "$(cat "$TEMP_ROOT/target-request")" = PING ]
[ "$(wc -c < "$TEMP_ROOT/client-response")" -eq $((2 + ${#MARKER})) ]
[ "$(od -An -tu1 -N2 "$TEMP_ROOT/client-response" | tr -d ' \n')" = 00 ]
[ "$(dd if="$TEMP_ROOT/client-response" bs=1 skip=2 2>/dev/null)" = "$MARKER" ]

echo "GTAGod gtagate-to-GTACore data path check passed"

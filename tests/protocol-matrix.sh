#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CORE="$REPO_ROOT/bin/gtacore"
TEMPLATE="$REPO_ROOT/tests/fixtures/gtacore-nine-axis.json"
TEMP_ROOT=$(mktemp -d)
CORE_PID=""

cleanup() {
    if [ -n "$CORE_PID" ] && kill -0 "$CORE_PID" 2>/dev/null; then
        kill -TERM "$CORE_PID" 2>/dev/null || true
        wait "$CORE_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup 0 1 2 15

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=bench.local' \
    -addext 'subjectAltName=DNS:bench.local' \
    -keyout "$TEMP_ROOT/key.pem" \
    -out "$TEMP_ROOT/cert.pem" >/dev/null 2>&1

jq --arg cert "$TEMP_ROOT/cert.pem" --arg key "$TEMP_ROOT/key.pem" '
    walk(
        if type == "object" and .certificate_path? == "__CERT_PATH__" then
            .certificate_path = $cert | .key_path = $key
        else
            .
        end
    )
' "$TEMPLATE" > "$TEMP_ROOT/config.json"

"$CORE" sing-box check -c "$TEMP_ROOT/config.json"
printf 'gtagod-protocol-matrix-token\n' > "$TEMP_ROOT/token"
chmod 600 "$TEMP_ROOT/token"

"$CORE" run \
    --config "$TEMP_ROOT/config.json" \
    --host 127.0.0.1 \
    --port 0 \
    --token-file "$TEMP_ROOT/token" \
    --max-connections 128 \
    --max-tcp-connections 128 \
    --max-data-plane-threads 512 \
    --log-file "$TEMP_ROOT/gtacore.log" \
    --log-max-size 1048576 &
CORE_PID=$!

eval "$(awk '
    /^socket_port_owned_by_pid\(\)/ { copy = 1 }
    /^GATE_PORT=/ { copy = 0 }
    copy { print }
' "$REPO_ROOT/healthcheck.sh")"

ports_ready() {
    for port in 19101 19102 19104 19106 19107 19108; do
        socket_port_owned_by_pid "$CORE_PID" tcp "$port" || return 1
    done
    for port in 19103 19105 19109; do
        socket_port_owned_by_pid "$CORE_PID" udp "$port" || return 1
    done
}

READY=false
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$CORE_PID" 2>/dev/null; then
        cat "$TEMP_ROOT/gtacore.log" >&2
        echo "gtacore exited before the nine-axis listeners became ready" >&2
        exit 1
    fi
    if ports_ready; then
        READY=true
        break
    fi
    sleep 1
done

if [ "$READY" != "true" ]; then
    cat "$TEMP_ROOT/gtacore.log" >&2
    echo "nine-axis listeners did not become ready" >&2
    exit 1
fi

kill -TERM "$CORE_PID"
if ! wait "$CORE_PID"; then
    cat "$TEMP_ROOT/gtacore.log" >&2
    echo "gtacore did not stop cleanly after the nine-axis smoke" >&2
    exit 1
fi
CORE_PID=""

echo "nine-axis protocol lifecycle checks passed"
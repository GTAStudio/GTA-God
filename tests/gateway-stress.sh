#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_ROOT=$(mktemp -d)
REQUESTS="${GATEWAY_STRESS_REQUESTS:-1024}"
CONCURRENCY="${GATEWAY_STRESS_CONCURRENCY:-128}"
PAYLOAD_MIB="${GATEWAY_STRESS_PAYLOAD_MIB:-1}"
MIN_THROUGHPUT_RATIO="${GATEWAY_STRESS_MIN_THROUGHPUT_RATIO:-40}"
ORIGIN_PID=""
GATE_PID=""
SLOW_PID=""

case "$PAYLOAD_MIB" in
    ''|*[!0-9]*)
        printf 'GATEWAY_STRESS_PAYLOAD_MIB must be an integer from 1 to 256\n' >&2
        exit 2
        ;;
esac
if [ "$PAYLOAD_MIB" -lt 1 ] || [ "$PAYLOAD_MIB" -gt 256 ]; then
    printf 'GATEWAY_STRESS_PAYLOAD_MIB must be an integer from 1 to 256\n' >&2
    exit 2
fi
case "$MIN_THROUGHPUT_RATIO" in
    ''|*[!0-9]*)
        printf 'GATEWAY_STRESS_MIN_THROUGHPUT_RATIO must be an integer from 0 to 100\n' >&2
        exit 2
        ;;
esac
if [ "$MIN_THROUGHPUT_RATIO" -gt 100 ]; then
    printf 'GATEWAY_STRESS_MIN_THROUGHPUT_RATIO must be an integer from 0 to 100\n' >&2
    exit 2
fi
PAYLOAD_BYTES=$((PAYLOAD_MIB * 1024 * 1024))

cleanup() {
    for pid in "$SLOW_PID" "$GATE_PID" "$ORIGIN_PID"; do
        [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "$SLOW_PID" "$GATE_PID" "$ORIGIN_PID"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT INT TERM

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    source "$HOME/.cargo/env"
fi

cd "$REPO_ROOT/gateway"
cargo +1.97.0 build --locked --release >/dev/null

dd if=/dev/zero of="$TEMP_ROOT/payload.bin" bs=1M count="$PAYLOAD_MIB" status=none
python3 - "$TEMP_ROOT/payload.bin" >"$TEMP_ROOT/origin.log" 2>&1 <<'PY' &
import asyncio
import sys

with open(sys.argv[1], "rb") as source:
    payload = source.read()

response_headers = (
    b"HTTP/1.1 200 OK\r\n"
    + f"Content-Length: {len(payload)}\r\n".encode("ascii")
    + b"Connection: close\r\n\r\n"
)
payload_view = memoryview(payload)
send_chunk = 256 * 1024

async def handle(reader, writer):
    try:
        request = await reader.readuntil(b"\r\n\r\n")
        if request.startswith(b"GET /download "):
            writer.write(response_headers)
            for offset in range(0, len(payload_view), send_chunk):
                writer.write(payload_view[offset : offset + send_chunk])
                await writer.drain()
        else:
            writer.write(
                b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError):
        pass
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except ConnectionError:
            pass


async def main():
    server = await asyncio.start_server(
        handle,
        "127.0.0.1",
        18081,
        backlog=512,
        reuse_address=True,
    )
    async with server:
        await server.serve_forever()


asyncio.run(main())
PY
ORIGIN_PID=$!

cat > "$TEMP_ROOT/gtagate.json" <<'JSON'
{
  "listen": "127.0.0.1:18444",
  "dispatch_timeout_secs": 3,
  "upstream_connect_timeout_secs": 3,
  "copy_buffer_size": 65536,
  "max_connections": 256,
  "max_handshake_connections": 128,
  "relay_idle_timeout_secs": 30,
  "default_upstream": "127.0.0.1:18081",
  "routes": []
}
JSON

"$REPO_ROOT/gateway/target/release/gtagate" "$TEMP_ROOT/gtagate.json" \
    >"$TEMP_ROOT/gtagate.log" 2>&1 &
GATE_PID=$!

for _attempt in $(seq 1 50); do
    if curl -fsS --connect-timeout 1 --max-time 2 \
        http://127.0.0.1:18444/download -o /dev/null; then
        break
    fi
    if ! kill -0 "$GATE_PID" 2>/dev/null; then
        cat "$TEMP_ROOT/gtagate.log" >&2
        exit 1
    fi
    sleep 0.1
done

baseline_threads=$(find "/proc/$GATE_PID/task" -mindepth 1 -maxdepth 1 -type d | wc -l)
baseline_fds=$(find "/proc/$GATE_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)
baseline_rss_kib=$(awk '/^VmRSS:/ { print $2 }' "/proc/$GATE_PID/status")

latency_percentile_ms() {
    percentile="$1"
    results_file="$2"
    awk -v expected_bytes="$PAYLOAD_BYTES" \
        '$1 == 0 && $2 == expected_bytes { print $3 }' "$results_file" |
        sort -n |
        awk -v percentile="$percentile" '
            { values[NR] = $1 }
            END {
                if (NR == 0) {
                    print "nan"
                    exit
                }
                rank = int((percentile * NR + 99) / 100)
                if (rank < 1) rank = 1
                printf "%.2f", values[rank] * 1000
            }
        '
}

export GATEWAY_STRESS_SLOW_READY="$TEMP_ROOT/slow-ready.txt"
python3 - <<'PY' &
import os
import socket
import time

sockets = []
for _ in range(256):
    try:
        connection = socket.create_connection(("127.0.0.1", 18444), timeout=2)
        connection.settimeout(None)
        sockets.append(connection)
    except OSError:
        pass
with open(os.environ["GATEWAY_STRESS_SLOW_READY"], "w", encoding="ascii") as output:
    output.write(str(len(sockets)))
time.sleep(3)
for connection in sockets:
    connection.close()
PY
SLOW_PID=$!

for _attempt in $(seq 1 50); do
    [ -f "$GATEWAY_STRESS_SLOW_READY" ] && break
    sleep 0.1
done
[ -f "$GATEWAY_STRESS_SLOW_READY" ]
slow_connected=$(cat "$GATEWAY_STRESS_SLOW_READY")
test "$slow_connected" -ge 200
slow_threads=$(find "/proc/$GATE_PID/task" -mindepth 1 -maxdepth 1 -type d | wc -l)
slow_fds=$(find "/proc/$GATE_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)
test "$slow_threads" -le $((baseline_threads + 4))
test "$slow_fds" -le $((baseline_fds + 16))
wait "$SLOW_PID"
SLOW_PID=""
sleep 2
post_slow_fds=$(find "/proc/$GATE_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)
test "$post_slow_fds" -le $((baseline_fds + 8))

export GATEWAY_STRESS_DIRECT_URL=http://127.0.0.1:18081/download
export GATEWAY_STRESS_DIRECT_RESULTS="$TEMP_ROOT/direct-results.txt"
: > "$GATEWAY_STRESS_DIRECT_RESULTS"
direct_start_ns=$(date +%s%N)
seq 1 "$REQUESTS" | xargs -P "$CONCURRENCY" -I '{}' sh -c '
    size=$(curl -fsS --connect-timeout 3 --max-time 15 \
        -w "%{size_download} %{time_total}" "$GATEWAY_STRESS_DIRECT_URL" -o /dev/null 2>/dev/null)
    curl_rc=$?
    printf "%s %s\n" "$curl_rc" "${size:-0}" >> "$GATEWAY_STRESS_DIRECT_RESULTS"
'
direct_end_ns=$(date +%s%N)
direct_ok=$(awk -v expected_bytes="$PAYLOAD_BYTES" \
    '$1 == 0 && $2 == expected_bytes { count++ } END { print count + 0 }' \
    "$GATEWAY_STRESS_DIRECT_RESULTS")
if [ "$direct_ok" -ne "$REQUESTS" ]; then
    printf 'direct origin control failed: requests=%s concurrency=%s ok=%s\n' \
        "$REQUESTS" "$CONCURRENCY" "$direct_ok" >&2
    sort "$GATEWAY_STRESS_DIRECT_RESULTS" | uniq -c >&2
    exit 1
fi

export GATEWAY_STRESS_URL=http://127.0.0.1:18444/download
export GATEWAY_STRESS_RESULTS="$TEMP_ROOT/results.txt"
: > "$GATEWAY_STRESS_RESULTS"
clock_ticks=$(getconf CLK_TCK)
gateway_cpu_start=$(awk '{ print $14 + $15 }' "/proc/$GATE_PID/stat")
gateway_start_ns=$(date +%s%N)
seq 1 "$REQUESTS" | xargs -P "$CONCURRENCY" -I '{}' sh -c '
    size=$(curl -fsS --connect-timeout 3 --max-time 15 \
        -w "%{size_download} %{time_total}" "$GATEWAY_STRESS_URL" -o /dev/null 2>/dev/null)
    curl_rc=$?
    printf "%s %s\n" "$curl_rc" "${size:-0}" >> "$GATEWAY_STRESS_RESULTS"
'
gateway_end_ns=$(date +%s%N)
gateway_cpu_end=$(awk '{ print $14 + $15 }' "/proc/$GATE_PID/stat")

ok_count=$(awk -v expected_bytes="$PAYLOAD_BYTES" \
    '$1 == 0 && $2 == expected_bytes { count++ } END { print count + 0 }' \
    "$GATEWAY_STRESS_RESULTS")
failure_count=$((REQUESTS - ok_count))
if [ "$failure_count" -ne 0 ]; then
    printf 'gateway stress failed: requests=%s concurrency=%s ok=%s failures=%s\n' \
        "$REQUESTS" "$CONCURRENCY" "$ok_count" "$failure_count" >&2
    sort "$GATEWAY_STRESS_RESULTS" | uniq -c >&2
    printf '%s\n' '--- gtagate log ---' >&2
    tail -100 "$TEMP_ROOT/gtagate.log" >&2
    printf '%s\n' '--- process state ---' >&2
    ps -o pid,ppid,stat,etimes,nlwp,rss,wchan:32,comm,args -p "$GATE_PID" >&2 || true
    ls -l "/proc/$GATE_PID/fd" >&2 || true
    ss -H -tanp state established | grep -E ':(18444|18081)[[:space:]]' >&2 || true
    exit 1
fi

sleep 2
kill -0 "$GATE_PID"
threads=$(find "/proc/$GATE_PID/task" -mindepth 1 -maxdepth 1 -type d | wc -l)
fds=$(find "/proc/$GATE_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)
rss_kib=$(awk '/^VmRSS:/ { print $2 }' "/proc/$GATE_PID/status")

direct_seconds=$(awk -v start="$direct_start_ns" -v end="$direct_end_ns" \
    'BEGIN { printf "%.6f", (end - start) / 1000000000 }')
gateway_seconds=$(awk -v start="$gateway_start_ns" -v end="$gateway_end_ns" \
    'BEGIN { printf "%.6f", (end - start) / 1000000000 }')
direct_mib_s=$(awk -v requests="$REQUESTS" -v seconds="$direct_seconds" \
    -v payload_mib="$PAYLOAD_MIB" \
    'BEGIN { printf "%.1f", requests * payload_mib / seconds }')
gateway_mib_s=$(awk -v requests="$REQUESTS" -v seconds="$gateway_seconds" \
    -v payload_mib="$PAYLOAD_MIB" \
    'BEGIN { printf "%.1f", requests * payload_mib / seconds }')
throughput_ratio=$(awk -v direct="$direct_seconds" -v gateway="$gateway_seconds" \
    'BEGIN { printf "%.1f", direct / gateway * 100 }')
gateway_cpu_pct=$(awk \
    -v ticks="$((gateway_cpu_end - gateway_cpu_start))" \
    -v clock_ticks="$clock_ticks" \
    -v seconds="$gateway_seconds" \
    'BEGIN { printf "%.1f", ticks / clock_ticks / seconds * 100 }')
direct_p50_ms=$(latency_percentile_ms 50 "$GATEWAY_STRESS_DIRECT_RESULTS")
direct_p95_ms=$(latency_percentile_ms 95 "$GATEWAY_STRESS_DIRECT_RESULTS")
direct_p99_ms=$(latency_percentile_ms 99 "$GATEWAY_STRESS_DIRECT_RESULTS")
gateway_p50_ms=$(latency_percentile_ms 50 "$GATEWAY_STRESS_RESULTS")
gateway_p95_ms=$(latency_percentile_ms 95 "$GATEWAY_STRESS_RESULTS")
gateway_p99_ms=$(latency_percentile_ms 99 "$GATEWAY_STRESS_RESULTS")

test "$threads" -le $((baseline_threads + 4))
test "$fds" -le $((baseline_fds + 8))
test "$rss_kib" -le $((baseline_rss_kib + 16384))
printf 'performance: direct %s MiB/s in %ss (p50/p95/p99 %s/%s/%s ms); gateway %s MiB/s in %ss (p50/p95/p99 %s/%s/%s ms); throughput ratio %s%%; gtagate CPU %s%%\n' \
    "$direct_mib_s" "$direct_seconds" "$direct_p50_ms" "$direct_p95_ms" "$direct_p99_ms" \
    "$gateway_mib_s" "$gateway_seconds" "$gateway_p50_ms" "$gateway_p95_ms" "$gateway_p99_ms" \
    "$throughput_ratio" "$gateway_cpu_pct"
if ! awk -v actual="$throughput_ratio" -v minimum="$MIN_THROUGHPUT_RATIO" \
    'BEGIN { exit !(actual >= minimum) }'; then
    printf 'gateway throughput regression: ratio=%s%% minimum=%s%%\n' \
        "$throughput_ratio" "$MIN_THROUGHPUT_RATIO" >&2
    exit 1
fi

printf 'gateway stress passed: slow-handshake %s/%s bounded at %s FDs; %sx%sMiB @%s; threads %s->%s; fds %s->%s; RSS_KiB %s->%s\n' \
    "$slow_connected" 256 "$slow_fds" \
    "$REQUESTS" "$PAYLOAD_MIB" "$CONCURRENCY" "$baseline_threads" "$threads" \
    "$baseline_fds" "$fds" "$baseline_rss_kib" "$rss_kib"
#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_ROOT=$(mktemp -d)
TCP_PID=""
UDP_PID=""
OTHER_PID=""

cleanup() {
    for pid in "$TCP_PID" "$UDP_PID" "$OTHER_PID"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    for pid in "$TCP_PID" "$UDP_PID" "$OTHER_PID"; do
        [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
    done
    rm -rf "$TEMP_ROOT"
}
trap cleanup 0 1 2 15

eval "$(awk '
    /^socket_port_owned_by_pid\(\)/ { copy = 1 }
    /^GATE_PORT=/ { copy = 0 }
    copy { print }
' "$REPO_ROOT/healthcheck.sh")"

TCP_PORT=39081
UDP_PORT=39082
python3 -m http.server "$TCP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
TCP_PID=$!
python3 -c "import socket,time; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',$UDP_PORT)); time.sleep(30)" >/dev/null 2>&1 &
UDP_PID=$!
sleep 30 &
OTHER_PID=$!

SOCKETS_READY=false
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if socket_port_owned_by_pid "$TCP_PID" tcp "$TCP_PORT" \
        && socket_port_owned_by_pid "$UDP_PID" udp "$UDP_PORT"; then
        SOCKETS_READY=true
        break
    fi
    sleep 1
done
[ "$SOCKETS_READY" = "true" ]

socket_port_owned_by_pid "$TCP_PID" tcp "$TCP_PORT"
! socket_port_owned_by_pid "$OTHER_PID" tcp "$TCP_PORT"
socket_port_owned_by_pid "$UDP_PID" udp "$UDP_PORT"
! socket_port_owned_by_pid "$OTHER_PID" udp "$UDP_PORT"

kill "$TCP_PID" "$UDP_PID" "$OTHER_PID" 2>/dev/null || true
wait "$TCP_PID" "$UDP_PID" "$OTHER_PID" 2>/dev/null || true
TCP_PID=""
UDP_PID=""
OTHER_PID=""

eval "$(awk '
    /^build_gtacore_optional_limit_args\(\)/ { copy = 1 }
    /^if GTACORE_RUN_HELP=/ { copy = 0 }
    copy { print }
' "$REPO_ROOT/docker-entrypoint.sh")"

# Referenced by build_gtacore_optional_limit_args loaded dynamically above.
# shellcheck disable=SC2034
GTACORE_MAX_TCP_CONNECTIONS=2048
# shellcheck disable=SC2034
GTACORE_MAX_DATA_PLANE_THREADS=6144
CURRENT_RUN_HELP=$($REPO_ROOT/bin/gtacore run --help 2>&1)
build_gtacore_optional_limit_args "$CURRENT_RUN_HELP" >/dev/null
case "$GTACORE_OPTIONAL_LIMIT_ARGS" in
        *'--max-tcp-connections 2048'*'--max-data-plane-threads 6144'*) ;;
        *) echo "bundled gtacore does not expose the required resource-budget flags" >&2; exit 1 ;;
esac

build_gtacore_optional_limit_args '
  --max-tcp-connections <MAX_TCP_CONNECTIONS>
  --max-data-plane-threads <MAX_DATA_PLANE_THREADS>
' >/dev/null
case "$GTACORE_OPTIONAL_LIMIT_ARGS" in
    *'--max-tcp-connections 2048'*'--max-data-plane-threads 6144'*) ;;
    *) echo "supported gtacore limit flags were not forwarded" >&2; exit 1 ;;
esac

eval "$(awk '
        /^validate_gtagate_sni_routes\(\)/ { copy = 1 }
        /^if ! validate_gtagate_sni_routes/ { copy = 0 }
        copy { print }
' "$REPO_ROOT/docker-entrypoint.sh")"

GTAGATE_CONFIG="$TEMP_ROOT/gtagate-routing.json"
GTACORE_RUNTIME_CONFIG="$TEMP_ROOT/gtacore-routing.json"
cat > "$GTACORE_RUNTIME_CONFIG" <<'EOF'
{"inbounds":[
    {"type":"naive","tag":"naive-in","listen":"127.0.0.1","listen_port":8443,
     "tls":{"server_name":"edge.example.com"}},
    {"type":"anytls","tag":"reality-in","listen":"127.0.0.1","listen_port":8445,
     "tls":{"server_name":"www.microsoft.com","reality":{"enabled":true,
     "handshake":{"server":"www.microsoft.com","server_port":443}}}}
]}
EOF
cat > "$GTAGATE_CONFIG" <<'EOF'
{"default_upstream":"127.0.0.1:8444","routes":[
    {"sni":"*.example.com","upstream":"127.0.0.1:8443"}
]}
EOF

if validate_gtagate_sni_routes 2> "$TEMP_ROOT/routing-error.log"; then
        echo "mismatched REALITY SNI route was incorrectly accepted" >&2
        exit 1
fi
grep -F 'inbound=reality-in sni=www.microsoft.com actual=127.0.0.1:8444 expected_port=8445' \
        "$TEMP_ROOT/routing-error.log" >/dev/null

cat > "$GTAGATE_CONFIG" <<'EOF'
{"default_upstream":"127.0.0.1:8444","routes":[
    {"sni":"*.example.com","upstream":"127.0.0.1:8443"},
    {"sni":"www.microsoft.com","upstream":"127.0.0.1:8445"}
]}
EOF

jq '.inbounds[1].tls.reality.handshake.server = "www.amazon.com"' \
    "$GTACORE_RUNTIME_CONFIG" > "$TEMP_ROOT/reality-mismatch.json"
mv "$TEMP_ROOT/reality-mismatch.json" "$GTACORE_RUNTIME_CONFIG"
if validate_gtagate_sni_routes 2> "$TEMP_ROOT/reality-error.log"; then
    echo "mismatched REALITY identity was incorrectly accepted" >&2
    exit 1
fi
grep -F 'inbound=reality-in server_name=www.microsoft.com handshake_server=www.amazon.com' \
    "$TEMP_ROOT/reality-error.log" >/dev/null

jq '.inbounds[1].tls.reality.handshake.server = "www.microsoft.com"' \
    "$GTACORE_RUNTIME_CONFIG" > "$TEMP_ROOT/reality-fixed.json"
mv "$TEMP_ROOT/reality-fixed.json" "$GTACORE_RUNTIME_CONFIG"
validate_gtagate_sni_routes

eval "$(awk '
    /^    certificate_label\(\)/ { copy = 1 }
    /^    if ! validate_tls_domain_coverage/ { copy = 0 }
    copy { sub(/^    /, ""); print }
' "$REPO_ROOT/docker-entrypoint.sh")"

ACME_CERT_DIR="$TEMP_ROOT/certs"
ACME_CA_LABEL=letsencrypt
# Referenced by certificate helpers loaded dynamically from docker-entrypoint.sh.
# shellcheck disable=SC2034
ACME_DOMAINS='api.example.com
*.example.net'
GTACORE_RUNTIME_CONFIG="$TEMP_ROOT/config.json"

cat > "$GTACORE_RUNTIME_CONFIG" <<'EOF'
{"inbounds":[
  {"tag":"exact","tls":{"server_name":"api.example.com","certificate_path":"pending","key_path":"pending"}},
  {"tag":"wild","tls":{"server_name":"edge.example.net","certificate_path":"pending","key_path":"pending"}}
]}
EOF

for domain in api.example.com '*.example.net'; do
    label=$(certificate_label "$domain")
    generation='generation-00000000000000000000000000000000'
    cert_dir="$ACME_CERT_DIR/$ACME_CA_LABEL/$label"
    mkdir -p "$cert_dir/.gtagate-generations/$generation"
    printf '%s\n' "$generation" > "$cert_dir/.gtagate-current"
    printf 'cert-%s\n' "$domain" > "$cert_dir/.gtagate-generations/$generation/$label.crt"
    printf 'key-%s\n' "$domain" > "$cert_dir/.gtagate-generations/$generation/$label.key"
done

validate_tls_domain_coverage
CERT_MAP=$(build_certificate_map)
[ "$(printf '%s' "$CERT_MAP" | jq 'length')" -eq 2 ]
[ "$(printf '%s' "$CERT_MAP" | jq -r '.["0"].cert')" != \
    "$(printf '%s' "$CERT_MAP" | jq -r '.["1"].cert')" ]
update_cert_paths "$CERT_MAP"
jq -e '.inbounds[0].tls.certificate_path | contains("api.example.com")' \
    "$GTACORE_RUNTIME_CONFIG" >/dev/null
jq -e '.inbounds[1].tls.certificate_path | contains("wildcard_.example.net")' \
    "$GTACORE_RUNTIME_CONFIG" >/dev/null
[ "$(certificate_map_state "$CERT_MAP" | wc -l)" -eq 4 ]

jq '.inbounds[1].tls.server_name = "deep.edge.example.net"' \
    "$GTACORE_RUNTIME_CONFIG" > "$TEMP_ROOT/deep.json"
mv "$TEMP_ROOT/deep.json" "$GTACORE_RUNTIME_CONFIG"
if validate_tls_domain_coverage 2>/dev/null; then
    echo "multi-level wildcard was incorrectly accepted" >&2
    exit 1
fi

echo "shell behavior checks passed"
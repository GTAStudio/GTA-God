#!/bin/sh

CONFIG_PATH="/tmp/sing-box-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/sing-box/config.json"
fi

# gtagate must always be running
pgrep -x gtagate >/dev/null 2>&1 || { echo "healthcheck: gtagate not running" >&2; exit 1; }

# Verify gtagate is actually accepting connections (not just alive but hung).
# nc (netcat-openbsd) is installed in the image; procfs fallback for minimal images.
if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 127.0.0.1 443 >/dev/null 2>&1 \
        || { echo "healthcheck: port 443 not accepting connections" >&2; exit 1; }
elif [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
    # Check for LISTEN state (0A) on port 443 (0x01BB) via procfs
    awk 'BEGIN{rc=1} $2 ~ /:01BB$/ && $4=="0A"{rc=0} END{exit rc}' \
        /proc/net/tcp /proc/net/tcp6 2>/dev/null \
        || { echo "healthcheck: no LISTEN socket on :443" >&2; exit 1; }
fi

if [ -f /tmp/gtagod-singbox-required ]; then
    pgrep -x gtacore >/dev/null 2>&1 || { echo "healthcheck: gtacore required but not running" >&2; exit 1; }
fi

# Verify certificate files once gtacore is running.
if pgrep -x gtacore >/dev/null 2>&1; then
    # gtacore is running, verify certificate if configured
    if [ -f "$CONFIG_PATH" ]; then
        CERT_PATH=$(jq -r '..|.certificate_path? // empty' "$CONFIG_PATH" 2>/dev/null | head -n 1)
        if [ -n "$CERT_PATH" ]; then
            [ -f "$CERT_PATH" ] || { echo "healthcheck: certificate not found: $CERT_PATH" >&2; exit 1; }
            [ -f "${CERT_PATH%.crt}.key" ] || { echo "healthcheck: key not found for: $CERT_PATH" >&2; exit 1; }
        fi
    fi
fi

exit 0
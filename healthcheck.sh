#!/bin/sh

CONFIG_PATH="/tmp/sing-box-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/sing-box/config.json"
fi

# gtagate must always be running
pgrep -x gtagate >/dev/null 2>&1 || { echo "healthcheck: gtagate not running" >&2; exit 1; }

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
#!/bin/sh

CONFIG_PATH="/tmp/sing-box-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/sing-box/config.json"
fi

# Caddy must always be running
pgrep -x caddy >/dev/null 2>&1 || { echo "healthcheck: caddy not running" >&2; exit 1; }

# sing-box may not be started yet if waiting for certificates
# Only fail if sing-box was previously running (PID file or process exists)
if pgrep -x sing-box >/dev/null 2>&1; then
    # sing-box is running, verify certificate if configured
    if [ -f "$CONFIG_PATH" ]; then
        CERT_PATH=$(jq -r '..|.certificate_path? // empty' "$CONFIG_PATH" 2>/dev/null | head -n 1)
        if [ -n "$CERT_PATH" ]; then
            [ -f "$CERT_PATH" ] || { echo "healthcheck: certificate not found: $CERT_PATH" >&2; exit 1; }
            [ -f "${CERT_PATH%.crt}.key" ] || { echo "healthcheck: key not found for: $CERT_PATH" >&2; exit 1; }
        fi
    fi
fi

exit 0
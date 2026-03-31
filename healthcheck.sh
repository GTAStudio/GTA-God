#!/bin/sh

CONFIG_PATH="/tmp/sing-box-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/sing-box/config.json"
fi

# Use -x for exact process name match to avoid false positives
pgrep -x caddy >/dev/null 2>&1 || { echo "healthcheck: caddy not running" >&2; exit 1; }
pgrep -x sing-box >/dev/null 2>&1 || { echo "healthcheck: sing-box not running" >&2; exit 1; }

if [ -f "$CONFIG_PATH" ]; then
    CERT_PATH=$(jq -r '..|.certificate_path? // empty' "$CONFIG_PATH" 2>/dev/null | head -n 1)
    if [ -n "$CERT_PATH" ]; then
        [ -f "$CERT_PATH" ] || { echo "healthcheck: certificate not found: $CERT_PATH" >&2; exit 1; }
        [ -f "${CERT_PATH%.crt}.key" ] || { echo "healthcheck: key not found for: $CERT_PATH" >&2; exit 1; }
    fi
fi

exit 0
#!/bin/sh

CONFIG_PATH="/tmp/sing-box-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
    CONFIG_PATH="/etc/sing-box/config.json"
fi

pgrep caddy >/dev/null 2>&1 || exit 1
pgrep sing-box >/dev/null 2>&1 || exit 1

if [ -f "$CONFIG_PATH" ]; then
    CERT_PATH=$(jq -r '..|.certificate_path? // empty' "$CONFIG_PATH" | head -n 1)
    if [ -n "$CERT_PATH" ]; then
        [ -f "$CERT_PATH" ] || exit 1
        [ -f "${CERT_PATH%.crt}.key" ] || exit 1
    fi
fi

exit 0
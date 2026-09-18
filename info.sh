#!/usr/bin/env bash
#
# Print the pg-node Certificate and API Key from an existing installation.
# Run as root:  sudo bash info.sh
#
set -Eeuo pipefail

PG_ENV_FILE="/opt/pg-node/.env"
PG_CERT_FILE="/var/lib/pg-node/certs/ssl_cert.pem"

if [ "$(id -u)" -ne 0 ]; then
    SELF="${BASH_SOURCE[0]:-}"
    if [ -n "$SELF" ] && [ -r "$SELF" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$SELF" "$@"
    fi
    echo "This script must be run as root." >&2
    exit 1
fi

[ -f "$PG_ENV_FILE" ] || { echo "Not found: $PG_ENV_FILE (is pg-node installed?)" >&2; exit 1; }

API_KEY="$(grep -E '^[[:space:]]*API_KEY[[:space:]]*=' "$PG_ENV_FILE" | head -n1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')" || true
SERVICE_PORT="$(grep -E '^[[:space:]]*SERVICE_PORT[[:space:]]*=' "$PG_ENV_FILE" | head -n1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')" || true
CERT=""
if [ -f "$PG_CERT_FILE" ]; then
    CERT="$(cat "$PG_CERT_FILE")"
fi

SERVER_IP="$(curl -4 -s --fail --max-time 5 ifconfig.io 2>/dev/null || curl -6 -s --fail --max-time 5 ifconfig.io 2>/dev/null || true)"
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -n "$SERVER_IP" ] || SERVER_IP="unknown"

SEP="======================================================================"

# Orange (256-color if available, otherwise bright yellow fallback).
if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    ORANGE=$'\033[38;5;208m'
else
    ORANGE=$'\033[33m'
fi
RESET=$'\033[0m'

printf '%s\n' "$SEP"
printf ' PasarGuard node info\n'
printf '%s\n' "$SEP"
printf ' Server IP    : '
printf '%s%s%s\n' "$ORANGE" "$SERVER_IP" "$RESET"
printf ' Service port : %s\n' "$SERVICE_PORT"
printf ' Certificate  : %s\n' "$PG_CERT_FILE"
printf ' API Key      : %s\n' "$API_KEY"
printf '%s\n' "$SEP"
printf '%s\n' '----- BEGIN CERTIFICATE (select & copy everything below) -----'
printf '%s%s%s\n' "$ORANGE" "$CERT" "$RESET"
printf '%s\n' '----- END CERTIFICATE -----'
printf '%s\n' "$SEP"
printf '%s\n' '----- API KEY -----'
printf '%s%s%s\n' "$ORANGE" "$API_KEY" "$RESET"
printf '%s\n' '----- END API KEY -----'
printf '%s\n' "$SEP"

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

SEP="======================================================================"
cat <<EOF
$SEP
 PasarGuard node info
$SEP
 Service port : ${SERVICE_PORT}
 Certificate  : ${PG_CERT_FILE}
 API Key      : ${API_KEY}
$SEP
----- BEGIN CERTIFICATE (select & copy everything below) -----
$CERT
----- END CERTIFICATE -----
$SEP
----- API KEY -----
${API_KEY}
----- END API KEY -----
$SEP
EOF

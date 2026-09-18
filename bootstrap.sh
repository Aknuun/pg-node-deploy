#!/usr/bin/env bash
#
# PasarGuard (pg-node) fully automated installer + xray-core setup.
#
# Steps:
#   1) apt update
#   2) configure + lock /etc/resolv.conf
#   3) install pg-node non-interactively (defaults, random free port if 62050 is busy)
#   4) download the xray core archive
#   5) install xray core, point pg-node at it and restart
#
# Run as root:  sudo bash install.sh
#
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
PG_APP_NAME="pg-node"
PG_APP_DIR="/opt/${PG_APP_NAME}"
PG_DATA_DIR="/var/lib/${PG_APP_NAME}"
PG_ENV_FILE="${PG_APP_DIR}/.env"
PG_CERT_FILE="${PG_DATA_DIR}/certs/ssl_cert.pem"
DEFAULT_PORT="62050"
XRAY_DIR="${PG_DATA_DIR}/xray-core"
XRAY_ZIP_URL="https://github.com/Aknuun/autonode-bot/releases/download/1.0/xray-amd64.zip"
INSTALLER_URL="https://github.com/PasarGuard/scripts/raw/main/pg-node.sh"
INFO_FILE="/root/pg-node-info.txt"

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Re-exec as root if needed. Use BASH_SOURCE so this also works when the
# script is sourced; never fall back to a bare `bash` (which would drop into
# an interactive shell when the script came in through a pipe).
if [ "$(id -u)" -ne 0 ]; then
    SELF="${BASH_SOURCE[0]:-}"
    if [ -n "$SELF" ] && [ -r "$SELF" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$SELF" "$@"
    fi
    die "This script must be run as root (try: sudo bash install.sh)."
fi

WORK_DIR="$(mktemp -d /tmp/pg-node-install.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# --------------------------------------------------------------------------
# Port helpers
# --------------------------------------------------------------------------
port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -H -tuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$"
    else
        return 1
    fi
}

pick_free_port() {
    local p i
    for i in $(seq 1 100); do
        p="$(shuf -i 20000-65000 -n 1 2>/dev/null || echo $(( (RANDOM % 45000) + 20000 )))"
        if ! port_in_use "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Step 1 - apt update
# --------------------------------------------------------------------------
log "Step 1/5 - apt update"
apt-get update -y || warn "apt-get update reported errors; continuing anyway."
ok "Package lists updated."

# --------------------------------------------------------------------------
# Step 2 - resolv.conf
# --------------------------------------------------------------------------
log "Step 2/5 - configuring /etc/resolv.conf"
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
printf 'nameserver 94.140.14.15\nnameserver 127.0.0.53\noptions edns0 trust-ad\nsearch .\n' \
    | tee /etc/resolv.conf >/dev/null
if chattr +i /etc/resolv.conf 2>/dev/null; then
    ok "/etc/resolv.conf written and locked (chattr +i)."
else
    warn "/etc/resolv.conf written, but chattr +i failed (unsupported filesystem?)."
fi

# --------------------------------------------------------------------------
# Step 3 - install pg-node
# --------------------------------------------------------------------------
log "Step 3/5 - installing PasarGuard node (non-interactive)"

command -v curl >/dev/null 2>&1 || { apt-get install -y curl; }

SERVICE_PORT="$DEFAULT_PORT"
if port_in_use "$SERVICE_PORT"; then
    warn "Default port ${DEFAULT_PORT} is already in use; picking a random free port."
    SERVICE_PORT="$(pick_free_port)" || die "Could not find a free service port."
    ok "Using random service port: ${SERVICE_PORT}"
else
    ok "Default service port ${DEFAULT_PORT} is free."
fi

log "Downloading pg-node installer..."
curl -fsSL "$INSTALLER_URL" -o "$WORK_DIR/pg-node.sh" \
    || die "Failed to download pg-node installer from $INSTALLER_URL"

log "Running pg-node install (defaults + port ${SERVICE_PORT})..."
set +e
bash "$WORK_DIR/pg-node.sh" install -y --service-port "$SERVICE_PORT" 2>&1 \
    | tee "$WORK_DIR/install.log"
INSTALL_RC="${PIPESTATUS[0]}"
set -e
[ "$INSTALL_RC" -eq 0 ] || die "pg-node installer exited with code ${INSTALL_RC}. See log above."

[ -f "$PG_ENV_FILE" ] || die "Installation finished but ${PG_ENV_FILE} was not found."

API_KEY="$(grep -E '^[[:space:]]*API_KEY[[:space:]]*=' "$PG_ENV_FILE" | head -n1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')" || true
ENV_PORT="$(grep -E '^[[:space:]]*SERVICE_PORT[[:space:]]*=' "$PG_ENV_FILE" | head -n1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')" || true
if [ -n "$ENV_PORT" ]; then
    SERVICE_PORT="$ENV_PORT"
fi

CERT=""
if [ -f "$PG_CERT_FILE" ]; then
    CERT="$(cat "$PG_CERT_FILE")"
fi

# --------------------------------------------------------------------------
# Step 4 - download xray core
# --------------------------------------------------------------------------
log "Step 4/5 - downloading xray core"
command -v wget  >/dev/null 2>&1 || { apt-get update -y; apt-get install -y wget; }
command -v unzip >/dev/null 2>&1 || { apt-get update -y; apt-get install -y unzip; }

wget -q -O "$WORK_DIR/xray-amd64.zip" "$XRAY_ZIP_URL" \
    || die "Failed to download xray core from $XRAY_ZIP_URL"
ok "Downloaded xray archive."

# --------------------------------------------------------------------------
# Step 5 - install xray core and point pg-node at it
# --------------------------------------------------------------------------
log "Step 5/5 - installing xray core"
mkdir -p "$XRAY_DIR"
cp -f "$WORK_DIR/xray-amd64.zip" "$XRAY_DIR/"

(
    cd "$XRAY_DIR"
    unzip -o xray-amd64.zip >/dev/null
    if [ -f xray-amd64 ]; then
        mv -f xray-amd64 xray
    elif [ ! -f xray ]; then
        # Fall back to whatever single binary the archive shipped.
        candidate="$(find . -maxdepth 1 -type f -not -name '*.zip' | head -n1)"
        if [ -n "$candidate" ]; then
            mv -f "$candidate" xray
        fi
    fi
    chmod +x xray 2>/dev/null || true
)

[ -f "$XRAY_DIR/xray" ] || die "xray binary was not found after extraction."

if grep -q '^XRAY_EXECUTABLE_PATH=' "$PG_ENV_FILE"; then
    sed -i "s|^XRAY_EXECUTABLE_PATH=.*|XRAY_EXECUTABLE_PATH=${XRAY_DIR}/xray|" "$PG_ENV_FILE"
else
    echo "XRAY_EXECUTABLE_PATH=${XRAY_DIR}/xray" >> "$PG_ENV_FILE"
fi
ok "XRAY_EXECUTABLE_PATH set to ${XRAY_DIR}/xray"

if command -v "$PG_APP_NAME" >/dev/null 2>&1; then
    log "Restarting pg-node (no log follow)..."
    "$PG_APP_NAME" restart -n || warn "pg-node restart returned a non-zero exit code."
else
    warn "pg-node CLI not found in PATH; skipping restart."
fi

# --------------------------------------------------------------------------
# Summary - show certificate + API key (copy from the terminal)
# --------------------------------------------------------------------------
SEP="======================================================================"
{
    echo "$SEP"
    echo " PasarGuard node installed - INSTALL DONE"
    echo "$SEP"
    echo " Service port : ${SERVICE_PORT}"
    echo " Certificate  : ${PG_CERT_FILE}"
    echo " API Key      : ${API_KEY}"
    echo "$SEP"
    echo "----- BEGIN CERTIFICATE (select & copy everything below) -----"
    echo "$CERT"
    echo "----- END CERTIFICATE -----"
    echo "$SEP"
    echo "----- API KEY -----"
    echo "${API_KEY}"
    echo "----- END API KEY -----"
    echo "$SEP"
} > "$INFO_FILE"
chmod 600 "$INFO_FILE"

cat "$INFO_FILE"

ok "All steps finished. A copy of this summary is saved at ${INFO_FILE}."

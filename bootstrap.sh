#!/usr/bin/env bash
#
# PasarGuard (pg-node) fully automated installer + custom xray-core setup,
# including automatic registration of the node in a PasarGuard panel.
#
# Steps:
#   1) apt update
#   2) configure + lock /etc/resolv.conf
#   3) install pg-node non-interactively (random free port if 62050/62051 are busy)
#   4) download the custom xray core
#   5) install xray core for this instance, point pg-node at it and restart
#   6) (optional) register the node in the panel
#
# Run as root:      sudo bash bootstrap.sh
# Custom instance:  sudo NODE_INSTANCE=fin3 bash bootstrap.sh
#
set -Eeuo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
DEFAULT_INSTANCE="pg-node"
DEFAULT_PORT="62050"
DEFAULT_API_PORT="62051"
XRAY_ZIP_URL="https://github.com/Aknuun/autonode-bot/releases/download/1.0/xray-amd64.zip"
INSTALLER_URL="https://github.com/PasarGuard/scripts/raw/main/pg-node.sh"
REPO_RAW="https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main"
REGISTER_SCRIPT_NAME="register-node.sh"
PANEL_CONF_FILE="${PANEL_CONF_FILE:-/etc/pg-node-deploy/panel.conf}"

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

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# --------------------------------------------------------------------------
# Instance name - several pg-node installs can coexist on one server.
# Resolution order: NODE_INSTANCE env -> interactive prompt (when an existing
# install is found) -> default "pg-node".
# --------------------------------------------------------------------------
validate_instance_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ ]]
}

INSTANCE="${NODE_INSTANCE:-}"
if [ -z "$INSTANCE" ]; then
    if [ -d "/opt/${DEFAULT_INSTANCE}" ]; then
        if [ -t 0 ]; then
            warn "An existing '${DEFAULT_INSTANCE}' install was found at /opt/${DEFAULT_INSTANCE}."
            printf '    Press Enter to (re)install on it, or type a new instance name: ' >&2
            read -r INSTANCE || true
            [ -n "$INSTANCE" ] || INSTANCE="$DEFAULT_INSTANCE"
        else
            warn "Existing '${DEFAULT_INSTANCE}' install found; reinstalling it (non-interactive)."
            INSTANCE="$DEFAULT_INSTANCE"
        fi
    else
        INSTANCE="$DEFAULT_INSTANCE"
    fi
fi

validate_instance_name "$INSTANCE" \
    || die "Invalid instance name '${INSTANCE}'. Use 1-63 chars: letters, digits, '_' or '-', starting with a letter or digit."

PG_APP_NAME="$INSTANCE"
PG_APP_DIR="/opt/${INSTANCE}"
PG_DATA_DIR="/var/lib/${INSTANCE}"
PG_ENV_FILE="${PG_APP_DIR}/.env"
PG_CERT_FILE="${PG_DATA_DIR}/certs/ssl_cert.pem"
XRAY_DIR="${PG_DATA_DIR}/xray-core"
INFO_FILE="/root/${INSTANCE}-info.txt"

log "Using pg-node instance: ${INSTANCE}"

WORK_DIR="$(mktemp -d /tmp/pg-node-install.XXXXXX)"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# True when everything needed to add this node to a panel is available,
# either through env vars or through the panel config file.
panel_credentials_available() {
    if [ -n "${PANEL_URL:-}" ] && [ -n "${PANEL_USERNAME:-}" ] && [ -n "${PANEL_PASSWORD:-}" ]; then
        return 0
    fi
    if [ -f "$PANEL_CONF_FILE" ] \
        && grep -Eq '^[[:space:]]*PANEL_URL[[:space:]]*=' "$PANEL_CONF_FILE" \
        && grep -Eq '^[[:space:]]*PANEL_USERNAME[[:space:]]*=' "$PANEL_CONF_FILE" \
        && grep -Eq '^[[:space:]]*PANEL_PASSWORD[[:space:]]*=' "$PANEL_CONF_FILE"; then
        return 0
    fi
    return 1
}

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
    pick_free_port_except ""
}

pick_free_port_except() {
    local exclude="$1" p i
    for i in $(seq 1 100); do
        p="$(shuf -i 20000-65000 -n 1 2>/dev/null || echo $(( (RANDOM % 45000) + 20000 )))"
        if [ "$p" != "$exclude" ] && ! port_in_use "$p"; then
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

API_PORT="$DEFAULT_API_PORT"
if port_in_use "$API_PORT" || [ "$API_PORT" = "$SERVICE_PORT" ]; then
    warn "Default API port ${DEFAULT_API_PORT} is unavailable; picking a random free port."
    API_PORT="$(pick_free_port_except "$SERVICE_PORT")" || die "Could not find a free API port."
    ok "Using random API port: ${API_PORT}"
else
    ok "Default API port ${DEFAULT_API_PORT} is free."
fi

log "Downloading pg-node installer..."
curl -fsSL "$INSTALLER_URL" -o "$WORK_DIR/pg-node.sh" \
    || die "Failed to download pg-node installer from $INSTALLER_URL"

log "Running pg-node install (instance=${INSTANCE}, service port=${SERVICE_PORT}, api port=${API_PORT})..."
set +e
bash "$WORK_DIR/pg-node.sh" install -y --name "$INSTANCE" \
    --service-port "$SERVICE_PORT" --api-port "$API_PORT" 2>&1 \
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
ENV_API_PORT="$(grep -E '^[[:space:]]*API_PORT[[:space:]]*=' "$PG_ENV_FILE" | head -n1 \
    | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//')" || true
if [ -n "$ENV_API_PORT" ]; then
    API_PORT="$ENV_API_PORT"
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
SERVER_IP="$(curl -4 -s --fail --max-time 5 ifconfig.io 2>/dev/null || curl -6 -s --fail --max-time 5 ifconfig.io 2>/dev/null || true)"
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -n "$SERVER_IP" ] || SERVER_IP="unknown"

# Panel node name: <public-ip>-<hostname> for the default instance,
# <public-ip>-<instance> for a custom one.
if [ "$INSTANCE" = "$DEFAULT_INSTANCE" ]; then
    NODE_SUFFIX="$(hostname -s 2>/dev/null || echo "$SERVER_IP")"
else
    NODE_SUFFIX="$INSTANCE"
fi
NODE_NAME="${NODE_NAME:-${SERVER_IP}-${NODE_SUFFIX}}"

SEP="======================================================================"

# Orange (256-color if available, otherwise bright yellow fallback).
if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 8)" -ge 256 ]; then
    ORANGE=$'\033[38;5;208m'
else
    ORANGE=$'\033[33m'
fi
RESET=$'\033[0m'

# Plain-text copy saved to disk.
{
    echo "$SEP"
    echo " PasarGuard node installed - INSTALL DONE"
    echo "$SEP"
    echo " Instance     : ${INSTANCE}"
    echo " Node name    : ${NODE_NAME}"
    echo " Server IP    : ${SERVER_IP}"
    echo " Service port : ${SERVICE_PORT}"
    echo " API port     : ${API_PORT}"
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

# Colored terminal output (certificate + API key in orange).
printf '%s\n' "$SEP"
printf ' PasarGuard node installed - INSTALL DONE\n'
printf '%s\n' "$SEP"
printf ' Instance     : %s\n' "$INSTANCE"
printf ' Node name    : '
printf '%s%s%s\n' "$ORANGE" "$NODE_NAME" "$RESET"
printf ' Server IP    : '
printf '%s%s%s\n' "$ORANGE" "$SERVER_IP" "$RESET"
printf ' Service port : %s\n' "$SERVICE_PORT"
printf ' API port     : %s\n' "$API_PORT"
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

ok "All steps finished. A copy of this summary is saved at ${INFO_FILE}."

# --------------------------------------------------------------------------
# Optional - register this node in the panel
# --------------------------------------------------------------------------
if panel_credentials_available; then
    log "Registering node in the panel..."
    REGISTER_SCRIPT=""
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$REGISTER_SCRIPT_NAME" ]; then
        REGISTER_SCRIPT="$SCRIPT_DIR/$REGISTER_SCRIPT_NAME"
    else
        REGISTER_SCRIPT="$WORK_DIR/$REGISTER_SCRIPT_NAME"
        if ! curl -fsSL "$REPO_RAW/$REGISTER_SCRIPT_NAME" -o "$REGISTER_SCRIPT"; then
            warn "Could not download ${REGISTER_SCRIPT_NAME}; skipping panel registration."
            REGISTER_SCRIPT=""
        fi
    fi
    if [ -n "$REGISTER_SCRIPT" ]; then
        if NODE_INSTANCE="$INSTANCE" NODE_NAME="$NODE_NAME" bash "$REGISTER_SCRIPT"; then
            ok "Panel registration finished."
        else
            warn "Panel registration failed. You can retry later with: sudo NODE_INSTANCE=${INSTANCE} bash ${REGISTER_SCRIPT_NAME}"
        fi
    fi
else
    warn "No panel credentials found (PANEL_URL/PANEL_USERNAME/PANEL_PASSWORD or ${PANEL_CONF_FILE})."
    warn "Skipping panel registration. Run it later with: sudo NODE_INSTANCE=${INSTANCE} bash ${REGISTER_SCRIPT_NAME}"
fi

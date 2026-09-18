#!/usr/bin/env bash
#
# Register this PasarGuard (pg-node) server in a PasarGuard panel.
#
# It reads the local node details (API key, service/api ports, certificate)
# from the installed pg-node, authenticates to the panel as an admin and
# creates the node through the panel REST API (POST /api/node).
#
# Panel credentials are resolved in this order (first non-empty wins):
#   1) CLI flags:  --panel-url --panel-username --panel-password
#   2) Environment variables: PANEL_URL, PANEL_USERNAME, PANEL_PASSWORD
#   3) Config file: /etc/pg-node-deploy/panel.conf (override with PANEL_CONF_FILE)
#
# Optional values (env, config file or flags):
#   NODE_INSTANCE          local pg-node instance name (default: pg-node)
#   PANEL_CORE_CONFIG_ID   core config id on the panel (default: 1)
#   PANEL_CONNECTION_TYPE  grpc | nats (default: grpc)
#   NODE_NAME              node name shown in the panel
#                          (default: <public-ip>-<hostname> for the default
#                          instance, <public-ip>-<instance> otherwise)
#   NODE_ADDRESS           address the panel uses to reach this node
#                          (default: auto-detected public IP)
#
# Run as root:  sudo bash register-node.sh
# Custom instance: sudo NODE_INSTANCE=fin3 bash register-node.sh
#
set -Eeuo pipefail

PANEL_CONF_FILE="${PANEL_CONF_FILE:-/etc/pg-node-deploy/panel.conf}"
DEFAULT_INSTANCE="pg-node"
DEFAULT_API_PORT="62051"

export DEBIAN_FRONTEND=noninteractive

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Re-exec as root if needed.
if [ "$(id -u)" -ne 0 ]; then
    SELF="${BASH_SOURCE[0]:-}"
    if [ -n "$SELF" ] && [ -r "$SELF" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -E bash "$SELF" "$@"
    fi
    die "This script must be run as root (try: sudo bash register-node.sh)."
fi

# --------------------------------------------------------------------------
# CLI flags (highest precedence)
# --------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --panel-url)         PANEL_URL="${2:-}"; shift 2 ;;
        --panel-username)    PANEL_USERNAME="${2:-}"; shift 2 ;;
        --panel-password)    PANEL_PASSWORD="${2:-}"; shift 2 ;;
        --core-config-id)    PANEL_CORE_CONFIG_ID="${2:-}"; shift 2 ;;
        --connection-type)   PANEL_CONNECTION_TYPE="${2:-}"; shift 2 ;;
        --instance)          NODE_INSTANCE="${2:-}"; shift 2 ;;
        --node-name)         NODE_NAME="${2:-}"; shift 2 ;;
        --node-address)      NODE_ADDRESS="${2:-}"; shift 2 ;;
        --conf)              PANEL_CONF_FILE="${2:-}"; shift 2 ;;
        -h|--help)
            grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 30 || true
            exit 0
            ;;
        *) die "Unknown argument: $1 (use --help)" ;;
    esac
done

# --------------------------------------------------------------------------
# Config file (only fills values that are still empty)
# --------------------------------------------------------------------------
if [ -f "$PANEL_CONF_FILE" ]; then
    log "Reading panel config from ${PANEL_CONF_FILE}"
    while IFS='=' read -r key value; do
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        [ -z "$key" ] && continue
        case "$key" in \#*) continue ;; esac
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        case "$key" in
            PANEL_URL)            [ -n "${PANEL_URL:-}" ]            || PANEL_URL="$value" ;;
            PANEL_USERNAME)       [ -n "${PANEL_USERNAME:-}" ]       || PANEL_USERNAME="$value" ;;
            PANEL_PASSWORD)       [ -n "${PANEL_PASSWORD:-}" ]       || PANEL_PASSWORD="$value" ;;
            PANEL_CORE_CONFIG_ID) [ -n "${PANEL_CORE_CONFIG_ID:-}" ] || PANEL_CORE_CONFIG_ID="$value" ;;
            PANEL_CONNECTION_TYPE)[ -n "${PANEL_CONNECTION_TYPE:-}" ]|| PANEL_CONNECTION_TYPE="$value" ;;
            NODE_INSTANCE)        [ -n "${NODE_INSTANCE:-}" ]        || NODE_INSTANCE="$value" ;;
            NODE_NAME)            [ -n "${NODE_NAME:-}" ]            || NODE_NAME="$value" ;;
            NODE_ADDRESS)         [ -n "${NODE_ADDRESS:-}" ]         || NODE_ADDRESS="$value" ;;
        esac
    done < "$PANEL_CONF_FILE"
fi

# --------------------------------------------------------------------------
# Interactive fallback (only when attached to a terminal)
# --------------------------------------------------------------------------
if [ -z "${PANEL_URL:-}" ]; then
    if [ -t 0 ]; then
        read -r -p "Panel URL (e.g. https://panel.example.com): " PANEL_URL
    else
        die "PANEL_URL is not set. Define it as an env var, in ${PANEL_CONF_FILE}, or pass --panel-url."
    fi
fi
if [ -z "${PANEL_USERNAME:-}" ]; then
    if [ -t 0 ]; then
        read -r -p "Panel admin username: " PANEL_USERNAME
    else
        die "PANEL_USERNAME is not set."
    fi
fi
if [ -z "${PANEL_PASSWORD:-}" ]; then
    if [ -t 0 ]; then
        read -r -s -p "Panel admin password: " PANEL_PASSWORD; echo
    else
        die "PANEL_PASSWORD is not set."
    fi
fi

PANEL_URL="${PANEL_URL%/}"
PANEL_CORE_CONFIG_ID="${PANEL_CORE_CONFIG_ID:-1}"
PANEL_CONNECTION_TYPE="${PANEL_CONNECTION_TYPE:-grpc}"

[ -n "$PANEL_URL" ]      || die "Panel URL is empty."
[ -n "$PANEL_USERNAME" ] || die "Panel username is empty."
[ -n "$PANEL_PASSWORD" ] || die "Panel password is empty."

# --------------------------------------------------------------------------
# Local instance paths
# --------------------------------------------------------------------------
NODE_INSTANCE="${NODE_INSTANCE:-$DEFAULT_INSTANCE}"
PG_ENV_FILE="/opt/${NODE_INSTANCE}/.env"
PG_CERT_FILE="/var/lib/${NODE_INSTANCE}/certs/ssl_cert.pem"

# --------------------------------------------------------------------------
# Local node info
# --------------------------------------------------------------------------
[ -f "$PG_ENV_FILE" ] || die "Not found: ${PG_ENV_FILE} (is pg-node instance '${NODE_INSTANCE}' installed?)"

envval() {
    grep -E "^[[:space:]]*$1[[:space:]]*=" "$PG_ENV_FILE" | head -n1 \
        | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//'
}

API_KEY="$(envval API_KEY || true)"
SERVICE_PORT="$(envval SERVICE_PORT || true)"
API_PORT="$(envval API_PORT || true)"
[ -n "$API_PORT" ] || API_PORT="$DEFAULT_API_PORT"

[ -n "$API_KEY" ]      || die "API_KEY not found in ${PG_ENV_FILE}."
[ -n "$SERVICE_PORT" ] || die "SERVICE_PORT not found in ${PG_ENV_FILE}."
[ -f "$PG_CERT_FILE" ] || die "Certificate not found: ${PG_CERT_FILE}."
CERT="$(cat "$PG_CERT_FILE")"

if [ -z "${NODE_ADDRESS:-}" ]; then
    NODE_ADDRESS="$(curl -4 -s --fail --max-time 5 ifconfig.io 2>/dev/null \
        || curl -6 -s --fail --max-time 5 ifconfig.io 2>/dev/null || true)"
    [ -n "$NODE_ADDRESS" ] || NODE_ADDRESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
[ -n "$NODE_ADDRESS" ] || die "Could not auto-detect the server IP; pass --node-address."

if [ -z "${NODE_NAME:-}" ]; then
    if [ "$NODE_INSTANCE" = "$DEFAULT_INSTANCE" ]; then
        NODE_SUFFIX="$(hostname -s 2>/dev/null || echo "$NODE_ADDRESS")"
    else
        NODE_SUFFIX="$NODE_INSTANCE"
    fi
    NODE_NAME="${NODE_ADDRESS}-${NODE_SUFFIX}"
fi

log "Registering node '${NODE_NAME}' (${NODE_ADDRESS}:${SERVICE_PORT}, api ${API_PORT}) in ${PANEL_URL}"

# --------------------------------------------------------------------------
# Dependencies
# --------------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y curl >/dev/null; }
command -v jq   >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y jq   >/dev/null; }

# --------------------------------------------------------------------------
# Authenticate
# --------------------------------------------------------------------------
log "Authenticating as '${PANEL_USERNAME}'..."
LOGIN_FILE="$(mktemp)"
LOGIN_CODE="$(curl -sS --max-time 15 -o "$LOGIN_FILE" -w '%{http_code}' -X POST "${PANEL_URL}/api/admin/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=${PANEL_USERNAME}" \
    --data-urlencode "password=${PANEL_PASSWORD}" 2>/dev/null)" \
    || { rm -f "$LOGIN_FILE"; die "Could not reach the panel at ${PANEL_URL}."; }

if [ "$LOGIN_CODE" != "200" ]; then
    err "Login failed (HTTP ${LOGIN_CODE})."
    jq -r '.detail? // empty' "$LOGIN_FILE" 2>/dev/null || true
    rm -f "$LOGIN_FILE"
    exit 1
fi

TOKEN="$(jq -r '.access_token // empty' "$LOGIN_FILE")"
rm -f "$LOGIN_FILE"
[ -n "$TOKEN" ] || die "Login succeeded but the panel did not return an access token."
ok "Authenticated."

# --------------------------------------------------------------------------
# Create the node
# --------------------------------------------------------------------------
BODY="$(jq -n \
    --arg name "$NODE_NAME" \
    --arg address "$NODE_ADDRESS" \
    --arg cert "$CERT" \
    --arg api_key "$API_KEY" \
    --arg connection_type "$PANEL_CONNECTION_TYPE" \
    --argjson port "$SERVICE_PORT" \
    --argjson api_port "$API_PORT" \
    --argjson core_config_id "$PANEL_CORE_CONFIG_ID" \
    '{
        name: $name,
        address: $address,
        port: $port,
        api_port: $api_port,
        usage_coefficient: 1,
        connection_type: $connection_type,
        server_ca: $cert,
        keep_alive: 60,
        core_config_id: $core_config_id,
        api_key: $api_key
    }')"

RESP_FILE="$(mktemp)"
HTTP_CODE="$(curl -sS --max-time 20 -o "$RESP_FILE" -w '%{http_code}' -X POST "${PANEL_URL}/api/node" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "$BODY" 2>/dev/null)" || { rm -f "$RESP_FILE"; die "Request to ${PANEL_URL}/api/node failed."; }

case "$HTTP_CODE" in
    200|201)
        ok "Node added to the panel successfully."
        jq -r '"   id: \(.id)   name: \(.name)   status: \(.status // "connecting")"' "$RESP_FILE" 2>/dev/null || true
        ;;
    409)
        warn "A node with the same name/address already exists on the panel (HTTP 409). Skipping."
        ;;
    401|403)
        err "Panel rejected the request (HTTP ${HTTP_CODE}): the admin lacks the 'nodes:create' permission."
        jq -r '.detail? // empty' "$RESP_FILE" 2>/dev/null || true
        rm -f "$RESP_FILE"; exit 1
        ;;
    *)
        err "Failed to add the node (HTTP ${HTTP_CODE})."
        jq -r '.detail? // .' "$RESP_FILE" 2>/dev/null || cat "$RESP_FILE"
        rm -f "$RESP_FILE"; exit 1
        ;;
esac

rm -f "$RESP_FILE"

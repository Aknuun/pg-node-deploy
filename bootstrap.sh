#!/usr/bin/env bash
#
# PasarGuard (pg-node) fully automated installer + custom xray-core setup,
# including automatic registration of the node in a PasarGuard panel.
#
# Steps:
#   1) apt update
#   2) configure + lock /etc/resolv.conf
#   3) tune nf_conntrack (RAM-based max + shorter timeouts, persistent)
#   4) install pg-node non-interactively (random free port if 62050/62051 are busy)
#   5) download the custom xray core
#   6) install xray core for this instance, point pg-node at it and restart
#   7) (optional) register the node in the panel
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
XRAY_VERSION="26.6.1"
XRAY_RELEASE_BASE="https://github.com/Aknuun/pg-node-deploy/releases/download/xray-${XRAY_VERSION}"
# NOTE: full ZIP URL is built per-arch in Step 5 (xray-amd64.zip / xray-arm64.zip).
# Use raw.githubusercontent.com directly (no github.com -> raw redirect, one less
# DNS + HTTP hop, more reliable when DNS is flaky).
INSTALLER_URL="https://raw.githubusercontent.com/PasarGuard/scripts/main/pg-node.sh"
INSTALLER_URL_FALLBACK="https://github.com/PasarGuard/scripts/raw/main/pg-node.sh"
REPO_RAW="https://raw.githubusercontent.com/Aknuun/pg-node-deploy/main"
REGISTER_SCRIPT_NAME="register-node.sh"
PANEL_CONF_FILE="${PANEL_CONF_FILE:-/etc/pg-node-deploy/panel.conf}"
# DNS config (Step 2) can be overridden:
#   SKIP_DNS_CONFIG=1      -> leave /etc/resolv.conf untouched
#   CUSTOM_DNS="8.8.8.8 1.1.1.1" -> use these nameservers instead of defaults
#   LOCK_RESOLV_CONF=0     -> don't chattr +i (useful on systems where the lock
#                             breaks later DHCP/systemd-resolved updates)
LOCK_RESOLV_CONF="${LOCK_RESOLV_CONF:-1}"

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# envval <file> <KEY> - read a value from a KEY=value file.
envval() {
    grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -n1 \
        | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'\'']//; s/["'\'']$//' || true
}

# --------------------------------------------------------------------------
# DNS helpers - Step 2 must never break name resolution, otherwise Step 4
# (pg-node.sh downloads its lib/*.sh from github.com) fails with:
#   curl: (28) Resolving timed out after 5001 milliseconds
#   Missing shared library: /usr/local/lib/pasarguard-scripts/lib/common.sh
# Strategy: backup existing resolv.conf, write candidates, verify each with a
# real DNS lookup for github.com + raw.githubusercontent.com, keep the first
# working set, and only chattr +i when resolution actually works.
# --------------------------------------------------------------------------
dns_resolves() {
    local host="$1"
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 && return 0
    fi
    # Fallback: quick curl DNS probe (no download).
    curl -s -o /dev/null --connect-timeout 5 --max-time 8 "https://${host}/" >/dev/null 2>&1 && return 0
    return 1
}

github_dns_ok() {
    dns_resolves "github.com" && dns_resolves "raw.githubusercontent.com"
}

configure_dns() {
    if [ "${SKIP_DNS_CONFIG:-0}" = "1" ]; then
        log "SKIP_DNS_CONFIG=1; leaving /etc/resolv.conf untouched."
        github_dns_ok || warn "Current DNS cannot resolve github.com; Step 4 may fail."
        return 0
    fi

    local candidates=()
    if [ -n "${CUSTOM_DNS:-}" ]; then
        # shellcheck disable=SC2206
        candidates+=(${CUSTOM_DNS})
    else
        # Order matters: 94.140.14.15 first, then 1.1.1.3, then the rest.
        # 127.0.0.53 (systemd stub) is only appended when the system was
        # using it before (symlink), because it breaks when resolv.conf is
        # no longer a symlink to /run/systemd/resolve/*.
        candidates=("94.140.14.15" "1.1.1.3" "8.8.8.8" "1.1.1.1" "9.9.9.9")
    fi

    # Backup current config so we can roll back if nothing works.
    local backup=""
    if [ -f /etc/resolv.conf ]; then
        backup="$(cat /etc/resolv.conf 2>/dev/null || true)"
        cp -f /etc/resolv.conf "$WORK_DIR/resolv.conf.bak" 2>/dev/null || true
    fi
    # Was it a symlink to systemd-resolved? Remember for the 127.0.0.53 check.
    local was_stub_symlink=0
    if [ -L /etc/resolv.conf ]; then
        case "$(readlink /etc/resolv.conf 2>/dev/null || true)" in
            *systemd*|*run/systemd/resolve*) was_stub_symlink=1 ;;
        esac
    fi

    chattr -i /etc/resolv.conf 2>/dev/null || true

    local ns_list="" ns primary_ok=0
    # Try: primary alone, primary+secondary, ... first working combo wins.
    for ns in "${candidates[@]}"; do
        if [ -z "$ns_list" ]; then
            ns_list="$ns"
        else
            ns_list="$ns_list $ns"
        fi
        {
            for s in $ns_list; do printf 'nameserver %s\n' "$s"; done
            # Keep systemd stub only when the system was using it before.
            if [ "$was_stub_symlink" = "1" ]; then
                printf 'nameserver 127.0.0.53\n'
            fi
            printf 'options edns0 trust-ad\nsearch .\n'
        } > /etc/resolv.conf
        sleep 1
        if github_dns_ok; then
            primary_ok=1
            ok "DNS verified with nameservers: $(echo $ns_list | tr ' ' ',') (github.com resolves)."
            break
        else
            warn "DNS candidate '${ns_list}' cannot resolve github.com; trying next..."
        fi
    done

    if [ "$primary_ok" != "1" ]; then
        warn "None of the candidate DNS servers resolved github.com."
        if [ -n "$backup" ]; then
            printf '%s' "$backup" > /etc/resolv.conf 2>/dev/null || true
            warn "Restored original /etc/resolv.conf."
            sleep 1
            github_dns_ok && ok "Original DNS resolves github.com; continuing with it." || warn "Even original DNS fails; continuing anyway (Step 4 will likely fail)."
        fi
        return 0
    fi

    if [ "$LOCK_RESOLV_CONF" = "1" ]; then
        if chattr +i /etc/resolv.conf 2>/dev/null; then
            ok "/etc/resolv.conf written and locked (chattr +i)."
        else
            warn "/etc/resolv.conf written, but chattr +i failed (unsupported filesystem?)."
        fi
    else
        ok "/etc/resolv.conf written (lock skipped, LOCK_RESOLV_CONF=0)."
    fi
}

# Download helper with retries + IPv4 fallback. Returns non-zero only when
# every attempt (normal + --ipv4) fails.
robust_download() {
    local url="$1" dest="$2"
    local attempt
    for attempt in 1 2 3; do
        if curl -fsSL --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2 "$url" -o "$dest"; then
            return 0
        fi
        warn "Download attempt ${attempt}/3 failed for ${url}; retrying..."
        sleep 2
    done
    warn "Standard download failed; retrying with --ipv4 for ${url}..."
    if curl -fsSL --ipv4 --connect-timeout 10 --max-time 60 "$url" -o "$dest"; then
        return 0
    fi
    return 1
}

# --------------------------------------------------------------------------
# conntrack tuning - RAM-based nf_conntrack_max + shorter timeouts.
# Rule: >= 4 GiB RAM -> 524288, 2-4 GiB -> 262144, < 2 GiB -> 131072.
# Override with CONNTRACK_MAX env (e.g. CONNTRACK_MAX=262144).
# Applies immediately (sysctl -w) and persists in /etc/sysctl.conf
# (idempotent: existing keys are replaced, never duplicated).
# Skipped gracefully on kernels without nf_conntrack.
# --------------------------------------------------------------------------
tune_conntrack() {
    local max="${CONNTRACK_MAX:-}"
    if [ ! -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
        warn "nf_conntrack not available in this kernel; skipping conntrack tuning."
        return 0
    fi
    if [ -z "$max" ]; then
        local mem_kb
        mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
        [ -n "$mem_kb" ] || mem_kb=0
        if [ "$mem_kb" -ge 4194304 ]; then
            max=524288
        elif [ "$mem_kb" -ge 2097152 ]; then
            max=262144
        else
            max=131072
        fi
        log "Total RAM: $(( mem_kb / 1024 )) MiB -> nf_conntrack_max=${max}"
    else
        log "CONNTRACK_MAX override: ${max}"
    fi
    sysctl -w net.netfilter.nf_conntrack_max="$max" >/dev/null || warn "Could not set nf_conntrack_max at runtime."
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=86400 >/dev/null || warn "Could not set tcp_established timeout."
    sysctl -w net.netfilter.nf_conntrack_udp_timeout=15 >/dev/null || warn "Could not set udp timeout."
    sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream=60 >/dev/null || warn "Could not set udp_stream timeout."
    sysctl -w net.netfilter.nf_conntrack_generic_timeout=300 >/dev/null || warn "Could not set generic timeout."
    local _k
    for _k in net.netfilter.nf_conntrack_max \
               net.netfilter.nf_conntrack_tcp_timeout_established \
               net.netfilter.nf_conntrack_udp_timeout \
               net.netfilter.nf_conntrack_udp_timeout_stream \
               net.netfilter.nf_conntrack_generic_timeout; do
        sed -i -E "/^[[:space:]]*${_k//./\\.}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null || true
    done
    cat >> /etc/sysctl.conf <<EOF
net.netfilter.nf_conntrack_max=${max}
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_udp_timeout=15
net.netfilter.nf_conntrack_udp_timeout_stream=60
net.netfilter.nf_conntrack_generic_timeout=300
EOF
    ok "conntrack tuned (max=${max}) and persisted in /etc/sysctl.conf."
}

# --------------------------------------------------------------------------
# Node-name helpers - format: <IP>-<first4-hostname>-<datacenter>
# e.g. 178.104.242.27-nure-hetzner
# Datacenter is auto-detected from the public IP (ip-api.com -> ipinfo.io),
# override with DATACENTER / NODE_DATACENTER env or panel.conf.
# --------------------------------------------------------------------------
slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-32
}

normalize_datacenter_name() {
    local raw="$1" hay
    hay="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
    case "$hay" in
        *hetzner*) echo hetzner; return 0 ;;
        *ovh*) echo ovh; return 0 ;;
        *digitalocean*|*digital*ocean*) echo digitalocean; return 0 ;;
        *vultr*|*choopa*|*constant*company*) echo vultr; return 0 ;;
        *linode*|*akamai*) echo linode; return 0 ;;
        *contabo*) echo contabo; return 0 ;;
        *netcup*) echo netcup; return 0 ;;
        *scaleway*|*online*sas*) echo scaleway; return 0 ;;
        *amazon*|*aws*) echo aws; return 0 ;;
        *google*|*gcp*) echo google; return 0 ;;
        *microsoft*|*azure*) echo azure; return 0 ;;
        *oracle*|*oci*) echo oracle; return 0 ;;
        *cloudflare*) echo cloudflare; return 0 ;;
        *leaseweb*) echo leaseweb; return 0 ;;
        *serverscom*|*servers.com*) echo serverscom; return 0 ;;
        *ionos*|*1and1*|*1-1*) echo ionos; return 0 ;;
        *aeza*) echo aeza; return 0 ;;
        *selectel*) echo selectel; return 0 ;;
        *timeweb*) echo timeweb; return 0 ;;
        *regru*|*reg.ru*) echo regru; return 0 ;;
        *beget*) echo beget; return 0 ;;
        *justhost*|*just*host*) echo justhost; return 0 ;;
        *firstvds*|*first*vds*) echo firstvds; return 0 ;;
        *alibaba*|*aliyun*) echo alibaba; return 0 ;;
        *tencent*) echo tencent; return 0 ;;
        *huawei*) echo huawei; return 0 ;;
    esac
    local first
    first="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | grep -o -E '[a-z0-9]+' | head -n1)"
    [ -n "$first" ] && { printf '%s\n' "$first"; return 0; }
    return 1
}

detect_datacenter() {
    local ip="${1:-}"
    local override="${DATACENTER:-${NODE_DATACENTER:-}}"
    if [ -z "$override" ] && [ -f "${PANEL_CONF_FILE:-/etc/pg-node-deploy/panel.conf}" ]; then
        override="$(grep -E '^[[:space:]]*(DATACENTER|NODE_DATACENTER)[[:space:]]*=' "${PANEL_CONF_FILE}" 2>/dev/null | head -n1 \
            | sed -E 's/^[^=]*=//; s/^[[:space:]]+//; s/^["'"'"']//; s/["'"'"']$//; s/^['"'"']//; s/['"'"']$//' || true)"
    fi
    if [ -n "$override" ]; then
        local s
        s="$(slugify "$override")"
        [ -n "$s" ] && { printf '%s\n' "$s"; return 0; }
    fi
    local raw="" json=""
    if command -v curl >/dev/null 2>&1 && [ -n "$ip" ] && [ "$ip" != "unknown" ]; then
        json="$(curl -s --max-time 8 "http://ip-api.com/json/${ip}?fields=status,org,isp,asname" 2>/dev/null || true)"
        if printf '%s' "$json" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
            local org isp asname
            org="$(printf '%s' "$json" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            isp="$(printf '%s' "$json" | sed -n 's/.*"isp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            asname="$(printf '%s' "$json" | sed -n 's/.*"asname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
            raw="${org} ${isp} ${asname}"
        fi
        if [ -z "$(printf '%s' "$raw" | tr -d ' ')" ]; then
            raw="$(curl -s --max-time 8 "https://ipinfo.io/${ip}/org" 2>/dev/null || true)"
        fi
    fi
    if [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ]; then
        local norm
        if norm="$(normalize_datacenter_name "$raw")" && [ -n "$norm" ]; then
            slugify "$norm"
            return 0
        fi
    fi
    printf 'dc\n'
}

build_node_name() {
    local ip="$1" instance="$2" default_instance="${3:-pg-node}"
    local host short dc
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-64)"
    [ -n "$host" ] || host="node"
    short="$(printf '%s' "$host" | tr -d '-' | cut -c1-4)"
    [ -n "$short" ] || short="node"
    dc="$(detect_datacenter "$ip")"
    [ -n "$dc" ] || dc="dc"
    if [ "$instance" = "$default_instance" ]; then
        printf '%s-%s-%s\n' "$ip" "$short" "$dc"
    else
        local inst_slug
        inst_slug="$(slugify "$instance")"
        [ -n "$inst_slug" ] || inst_slug="$instance"
        printf '%s-%s-%s-%s\n' "$ip" "$short" "$dc" "$inst_slug"
    fi
}

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

# --------------------------------------------------------------------------
# Panel node name - ask FIRST so the panel entry is ip+name.
# Final format: <server-ip>-<name> (custom instance appends -<instance>).
# Resolution order: NODE_NAME env (full) -> NODE_NAME_SUFFIX env -> interactive
# prompt (when a terminal is attached) -> auto (<IP>-<host4>-<datacenter>).
# Non-interactive runs never block: empty suffix means auto.
# --------------------------------------------------------------------------
NODE_NAME_SUFFIX="${NODE_NAME_SUFFIX:-}"
if [ -z "${NODE_NAME:-}" ] && [ -z "$NODE_NAME_SUFFIX" ] && [ -t 0 ]; then
    printf 'Panel node name - final format is ip+name, e.g. 178.104.242.27-myname\n' >&2
    printf 'Enter a name for this node in the panel (Enter = auto): ' >&2
    read -r NODE_NAME_SUFFIX || true
fi

PG_APP_NAME="$INSTANCE"
PG_APP_DIR="/opt/${INSTANCE}"
PG_DATA_DIR="/var/lib/${INSTANCE}"
PG_ENV_FILE="${PG_APP_DIR}/.env"
PG_CERT_FILE="${PG_DATA_DIR}/certs/ssl_cert.pem"
PG_KEY_FILE="${PG_DATA_DIR}/certs/ssl_key.pem"
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
log "Step 1/6 - apt update"
apt-get update -y || warn "apt-get update reported errors; continuing anyway."
ok "Package lists updated."

log "Installing nload (network traffic monitor)..."
if ! command -v nload >/dev/null 2>&1; then
    apt-get install -y nload >/dev/null 2>&1 || warn "Could not install nload; continuing anyway."
fi
command -v nload >/dev/null 2>&1 && ok "nload is installed." || warn "nload is not available."

# --------------------------------------------------------------------------
# Step 2 - resolv.conf (verified, never break DNS)
# --------------------------------------------------------------------------
log "Step 2/6 - configuring /etc/resolv.conf"
configure_dns

# --------------------------------------------------------------------------
# Step 3 - nf_conntrack tuning (RAM-based max, persistent)
# --------------------------------------------------------------------------
log "Step 3/6 - tuning nf_conntrack (RAM-based max, persistent)"
tune_conntrack

# --------------------------------------------------------------------------
# Step 4 - install pg-node
# --------------------------------------------------------------------------
log "Step 4/6 - installing PasarGuard node (non-interactive)"

command -v curl >/dev/null 2>&1 || { apt-get install -y curl; }

REINSTALL=false
EXISTING_API_KEY=""
if [ -f "$PG_ENV_FILE" ]; then
    REINSTALL=true
fi

SERVICE_PORT="$DEFAULT_PORT"
API_PORT="$DEFAULT_API_PORT"

if [ "$REINSTALL" = true ]; then
    # Keep the existing ports, API key and certificate so the panel entry
    # created earlier stays valid after the reinstall.
    EXISTING_SERVICE_PORT="$(envval "$PG_ENV_FILE" SERVICE_PORT)"
    EXISTING_API_PORT="$(envval "$PG_ENV_FILE" API_PORT)"
    EXISTING_API_KEY="$(envval "$PG_ENV_FILE" API_KEY)"
    [ -n "$EXISTING_SERVICE_PORT" ] && SERVICE_PORT="$EXISTING_SERVICE_PORT"
    [ -n "$EXISTING_API_PORT" ] && API_PORT="$EXISTING_API_PORT"
    log "Existing instance found; reusing ports ${SERVICE_PORT}/${API_PORT} and its API key."
    # Stop this instance's services so its ports are free for the installer.
    if command -v "$INSTANCE" >/dev/null 2>&1; then
        "$INSTANCE" down >/dev/null 2>&1 || true
        "$INSTANCE" service-stop >/dev/null 2>&1 || true
    fi
    sleep 2
else
    if port_in_use "$SERVICE_PORT"; then
        warn "Default port ${DEFAULT_PORT} is already in use; picking a random free port."
        SERVICE_PORT="$(pick_free_port)" || die "Could not find a free service port."
        ok "Using random service port: ${SERVICE_PORT}"
    else
        ok "Default service port ${DEFAULT_PORT} is free."
    fi

    if port_in_use "$API_PORT" || [ "$API_PORT" = "$SERVICE_PORT" ]; then
        warn "Default API port ${DEFAULT_API_PORT} is unavailable; picking a random free port."
        API_PORT="$(pick_free_port_except "$SERVICE_PORT")" || die "Could not find a free API port."
        ok "Using random API port: ${API_PORT}"
    else
        ok "Default API port ${DEFAULT_API_PORT} is free."
    fi
fi

log "Downloading pg-node installer..."
if ! robust_download "$INSTALLER_URL" "$WORK_DIR/pg-node.sh"; then
    warn "Primary installer URL failed; trying fallback: ${INSTALLER_URL_FALLBACK}"
    robust_download "$INSTALLER_URL_FALLBACK" "$WORK_DIR/pg-node.sh" \
        || die "Failed to download pg-node installer from $INSTALLER_URL (DNS or network blocked github.com; check /etc/resolv.conf, try CUSTOM_DNS=\"8.8.8.8 1.1.1.1\" or SKIP_DNS_CONFIG=1)"
fi

# Pre-flight: pg-node.sh will curl lib/*.sh from github.com with a 5s
# connect-timeout. Fail early with a clear message instead of the cryptic
# "Missing shared library: /usr/local/lib/pasarguard-scripts/lib/common.sh".
if ! github_dns_ok; then
    die "DNS cannot resolve github.com right now; pg-node installer would fail with 'Resolving timed out / Missing shared library'. Fix DNS (CUSTOM_DNS / SKIP_DNS_CONFIG=1) and retry."
fi

INSTALL_ARGS=(install -y --service-port "$SERVICE_PORT" --api-port "$API_PORT")
HIDDEN_CLI=""

if [ "$INSTANCE" != "$DEFAULT_INSTANCE" ]; then
    # The upstream installer rejects an explicit --name when a command with
    # that name already exists (e.g. our own CLI from a previous install).
    INSTALL_ARGS+=(--name "$INSTANCE")
    EXISTING_CMD="$(command -v "$INSTANCE" 2>/dev/null || true)"
    if [ -n "$EXISTING_CMD" ] && [ "$EXISTING_CMD" = "/usr/local/bin/${INSTANCE}" ] && [ -f "$EXISTING_CMD" ]; then
        HIDDEN_CLI="$EXISTING_CMD"
        mv -f "$HIDDEN_CLI" "${HIDDEN_CLI}.pg-node-deploy.bak"
        log "Temporarily hid ${HIDDEN_CLI} so the installer accepts --name ${INSTANCE}."
    fi
fi

if [ "$REINSTALL" = true ]; then
    [ -n "$EXISTING_API_KEY" ] && INSTALL_ARGS+=(--api-key "$EXISTING_API_KEY")
    if [ -f "$PG_CERT_FILE" ] && [ -f "$PG_KEY_FILE" ]; then
        cp -f "$PG_CERT_FILE" "$WORK_DIR/reuse-cert.pem"
        cp -f "$PG_KEY_FILE" "$WORK_DIR/reuse-key.pem"
        INSTALL_ARGS+=(--cert-path "$WORK_DIR/reuse-cert.pem" --key-path "$WORK_DIR/reuse-key.pem")
    fi
fi

log "Running pg-node install (instance=${INSTANCE}, service port=${SERVICE_PORT}, api port=${API_PORT})..."
set +e
bash "$WORK_DIR/pg-node.sh" "${INSTALL_ARGS[@]}" 2>&1 \
    | tee "$WORK_DIR/install.log"
INSTALL_RC="${PIPESTATUS[0]}"
set -e

# Restore the hidden CLI only if the installer did not recreate it.
if [ -n "$HIDDEN_CLI" ] && [ -f "${HIDDEN_CLI}.pg-node-deploy.bak" ]; then
    if [ ! -f "$HIDDEN_CLI" ]; then
        mv -f "${HIDDEN_CLI}.pg-node-deploy.bak" "$HIDDEN_CLI"
    else
        rm -f "${HIDDEN_CLI}.pg-node-deploy.bak"
    fi
fi

[ "$INSTALL_RC" -eq 0 ] || die "pg-node installer exited with code ${INSTALL_RC}. See log above."

[ -f "$PG_ENV_FILE" ] || die "Installation finished but ${PG_ENV_FILE} was not found."

API_KEY="$(envval "$PG_ENV_FILE" API_KEY)"
ENV_PORT="$(envval "$PG_ENV_FILE" SERVICE_PORT)"
if [ -n "$ENV_PORT" ]; then
    SERVICE_PORT="$ENV_PORT"
fi
ENV_API_PORT="$(envval "$PG_ENV_FILE" API_PORT)"
if [ -n "$ENV_API_PORT" ]; then
    API_PORT="$ENV_API_PORT"
fi

CERT=""
if [ -f "$PG_CERT_FILE" ]; then
    CERT="$(cat "$PG_CERT_FILE")"
fi

# --------------------------------------------------------------------------
# Step 4 - download xray core (amd64 + arm64)
# Custom core is built from ImMohammad20000/Xray-core@UserConnTracker
# (per-user connection tracker: forced disconnect when quota is exhausted).
# --------------------------------------------------------------------------
log "Step 5/6 - downloading xray core"
command -v wget  >/dev/null 2>&1 || { apt-get update -y; apt-get install -y wget; }
command -v unzip >/dev/null 2>&1 || { apt-get update -y; apt-get install -y unzip; }

detect_xray_arch() {
    local m
    m="$(uname -m 2>/dev/null || echo unknown)"
    case "$m" in
        x86_64|amd64) printf 'amd64\n'; return 0 ;;
        aarch64|arm64) printf 'arm64\n'; return 0 ;;
        *) return 1 ;;
    esac
}

XRAY_ARCH=""
XRAY_ARCH="$(detect_xray_arch)" \
    || die "Unsupported CPU architecture '$(uname -m)'. This installer supports x86_64 (amd64) and aarch64 (arm64) only."
XRAY_ZIP_NAME="xray-${XRAY_ARCH}.zip"
XRAY_ZIP_URL="${XRAY_RELEASE_BASE}/${XRAY_ZIP_NAME}"
log "Detected CPU arch: $(uname -m) -> ${XRAY_ARCH}; downloading ${XRAY_ZIP_NAME} (v${XRAY_VERSION})"

if command -v curl >/dev/null 2>&1; then
    robust_download "$XRAY_ZIP_URL" "$WORK_DIR/${XRAY_ZIP_NAME}" \
        || die "Failed to download xray core from $XRAY_ZIP_URL"
else
    wget --tries=3 --timeout=30 -O "$WORK_DIR/${XRAY_ZIP_NAME}" "$XRAY_ZIP_URL" \
        || die "Failed to download xray core from $XRAY_ZIP_URL"
fi
ok "Downloaded xray archive (${XRAY_ZIP_NAME})."

# --------------------------------------------------------------------------
# Step 5 - install xray core and point pg-node at it
# --------------------------------------------------------------------------
log "Step 6/6 - installing xray core (${XRAY_ARCH})"
mkdir -p "$XRAY_DIR"
cp -f "$WORK_DIR/${XRAY_ZIP_NAME}" "$XRAY_DIR/"

(
    cd "$XRAY_DIR"
    unzip -o "$XRAY_ZIP_NAME" >/dev/null
    if [ -f "xray-${XRAY_ARCH}" ]; then
        mv -f "xray-${XRAY_ARCH}" xray
    elif [ -f xray-amd64 ] && [ "$XRAY_ARCH" = "amd64" ]; then
        mv -f xray-amd64 xray
    elif [ -f xray-arm64 ] && [ "$XRAY_ARCH" = "arm64" ]; then
        mv -f xray-arm64 xray
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

# Panel node name: ip+name.
# - NODE_NAME env (full name) wins as-is.
# - NODE_NAME_SUFFIX (prompted above or via env) -> <IP>-<suffix>[-<instance>].
# - empty suffix -> auto <IP>-<first4-hostname>-<datacenter>[-<instance>].
# e.g. 178.104.242.27-myname
if [ -n "${NODE_NAME:-}" ]; then
    : # explicit full name, keep it
elif [ -n "${NODE_NAME_SUFFIX:-}" ]; then
    _suffix="$(slugify "$NODE_NAME_SUFFIX")"
    [ -n "$_suffix" ] || die "Invalid node name suffix '${NODE_NAME_SUFFIX}'. Use letters/digits/dash."
    if [ "$INSTANCE" != "$DEFAULT_INSTANCE" ]; then
        case "$_suffix" in
            *-"$INSTANCE") NODE_NAME="${SERVER_IP}-${_suffix}" ;;
            *) NODE_NAME="${SERVER_IP}-${_suffix}-$(slugify "$INSTANCE")" ;;
        esac
    else
        NODE_NAME="${SERVER_IP}-${_suffix}"
    fi
else
    NODE_NAME="$(build_node_name "$SERVER_IP" "$INSTANCE" "$DEFAULT_INSTANCE")"
fi

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
        if ! robust_download "$REPO_RAW/$REGISTER_SCRIPT_NAME" "$REGISTER_SCRIPT"; then
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

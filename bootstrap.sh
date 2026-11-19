#!/usr/bin/env bash
#
# PasarGuard (pg-node) fully automated installer + custom xray-core setup,
# including automatic registration of the node in a PasarGuard panel.
#
# Steps:
#   0) optional swap / zram sized from RAM (asked up front, Enter = yes / no)
#   1) apt update (+ journald cap and logrotate)
#   2) configure + lock /etc/resolv.conf
#   3) tune kernel: sysctl.d (tcp_mem/swappiness/file-max) + nf_conntrack
#      (+ optional BBR congestion control / fq qdisc, asked up front, Enter = yes)
#   4) install pg-node non-interactively (random free port if 62050/62051 are busy)
#   5) keep the stock xray core (default) or download the custom one
#   6) install xray core, disable IPv6, point pg-node at it and restart
#   7) (optional) register the node in the panel
#   +) health check and a summary box
#
# Run as root:      sudo bash bootstrap.sh
# Custom instance:  sudo NODE_INSTANCE=fin3 bash bootstrap.sh
# Non-interactive:  sudo bash bootstrap.sh --yes
# Help:             bash bootstrap.sh --help
#
set -Eeuo pipefail

SCRIPT_VERSION="2.5.1"
REPO_SLUG="Aknuun/pg-node-deploy"

usage() {
    cat <<EOF
pg-node-deploy ${SCRIPT_VERSION} - PasarGuard node installer

Usage: sudo bash bootstrap.sh [options]

  -y, --yes        non-interactive; use defaults (swap on, no adult filter, stock core, BBR on)
      --repair     reinstall over an existing instance, keeping ports, cert and API key
  -u, --uninstall  stop and remove this node instance (asks for confirmation)
  -h, --help       show this help
  -V, --version    show the script version

Environment:
  NODE_INSTANCE=pg-node        instance name (several installs can coexist)
  NODE_NAME_SUFFIX=myname      panel node name suffix (default: host + datacenter)
  ENABLE_SWAP=0|1              create /swapfile sized to RAM
  SWAP_SIZE_MB=4096            override the swap size
  ENABLE_ZRAM=0|1              add compressed swap in RAM (zram)
  BLOCK_PORN=0|1               filtered (Family) DNS
  INSTALL_CUSTOM_CORE=0|1      custom core with per-user tracker (default: 0 = stock)
  ENABLE_BBR=0|1               BBR + fq
  LANG_CODE=fa|en              messages language (auto from \$LANG)
  PANEL_URL / PANEL_USERNAME / PANEL_PASSWORD   register the node automatically
EOF
}

ASSUME_YES=0
REPAIR=0
UNINSTALL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --repair) ASSUME_YES=1; REPAIR=1 ;;
        -u|--uninstall) UNINSTALL=1 ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) echo "pg-node-deploy ${SCRIPT_VERSION}"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done


# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
DEFAULT_INSTANCE="pg-node"
DEFAULT_PORT="62050"
DEFAULT_API_PORT="62051"
# "latest" = newest release of this repo (assets must be xray-amd64.zip / xray-arm64.zip).
# Pin an exact version only if you need to freeze the core, e.g. XRAY_VERSION="26.10.31".
XRAY_VERSION="latest"
if [ "$XRAY_VERSION" = "latest" ]; then
    XRAY_RELEASE_BASE="https://github.com/Aknuun/pg-node-deploy/releases/latest/download"
else
    XRAY_RELEASE_BASE="https://github.com/Aknuun/pg-node-deploy/releases/download/xray-${XRAY_VERSION}"
fi
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
# Questions asked when a terminal is attached (Enter = yes):
#   ENABLE_SWAP=1       -> create a swap file sized to this server's RAM
#   ENABLE_ZRAM=1       -> also add compressed swap in RAM
#   BLOCK_PORN=1        -> use a Family DNS set that filters adult content
#   INSTALL_CUSTOM_CORE=1 -> install the custom core that ships with this repo
# Non-interactive runs (--yes / no terminal) enable all of the above.
BLOCK_PORN="${BLOCK_PORN:-}"
INSTALL_CUSTOM_CORE="${INSTALL_CUSTOM_CORE:-}"
# ENABLE_SWAP=1 -> create /swapfile sized from RAM (2G..8G), asked first when a
# terminal is attached. Non-interactive runs leave swap alone.
ENABLE_SWAP="${ENABLE_SWAP:-}"
# ENABLE_BBR=1 -> write /etc/sysctl.d/99-bbr-fq.conf (BBR + fq), applied in Step 3.
# Asked up front with the other setup questions when a terminal is attached
# (Enter = yes); non-interactive runs enable it.
ENABLE_BBR="${ENABLE_BBR:-}"

# Padding widths are counted in characters, so use a UTF-8 locale even when the
# server only has the C locale (otherwise ${#text} counts bytes).
if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
    export LC_ALL=C.UTF-8
fi

export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# Logging helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

# ask_yn "<question>" [y|n] [colour] - coloured yes/no prompt, Enter = default.
# colour is an ANSI code (35 magenta, 34 blue, 36 cyan, 33 yellow, 32 green).
ask_yn() {
    local q="$1" def="${2:-y}" colour="${3:-36}" ans hint
    if [ "$def" = "y" ]; then hint="Y/n"; else hint="y/N"; fi
    printf '\033[1;%sm[?] %s [%s]:\033[0m ' "$colour" "$q" "$hint" >&2
    read -r ans || true
    ans="${ans:-$def}"
    case "$ans" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}
die()  { err "$*"; exit 1; }

# --------------------------------------------------------------------------
# Language: LANG_CODE=fa switches the questions/summary to Persian.
# --------------------------------------------------------------------------
LANG_CODE="${LANG_CODE:-}"
if [ -z "$LANG_CODE" ]; then
    case "${LANG:-}" in
        fa*|*_IR*) LANG_CODE="fa" ;;
        *) LANG_CODE="en" ;;
    esac
fi

t() {
    local key="$1" s; shift
    case "${LANG_CODE}:${key}" in
        fa:node_name_q)  s="نام نود در پنل (فرمت نهایی ip+name، اینتر = خودکار): " ;;
        fa:swap_q)       s="فایل سواپ متناسب با رم سرور (%sM) ساخته شود؟" ;;
        fa:zram_q)       s="سواپ فشرده در رم (zram) هم اضافه شود؟" ;;
        fa:porn_q)       s="محتوای بزرگسال با DNS فیلترشده مسدود شود؟" ;;
        fa:core_q)       s="کر اختصاصی xray (با ردیاب اتصال هر کاربر) نصب شود؟" ;;
        fa:bbr_q)        s="BBR + fq فعال شود (سرعت و پایداری بهتر روی لینک‌های پرافت)؟" ;;
        fa:done)         s="نصب نود PasarGuard تمام شد" ;;
        fa:health)       s="بررسی سلامت نصب" ;;
        fa:uninstall_q)  s="حذف کامل این نود؟ نام نمونه را تایپ کن (%s): " ;;
        fa:mode_q)       s="نصب مستقیم شروع شود؟ (n = ورود به محیط CLI برای تغییر قابلیت‌ها)" ;;
        fa:cli_title)    s="محیط CLI - تنظیم قابلیت‌ها" ;;
        fa:cli_pick)     s="یک گزینه انتخاب کن" ;;
        fa:cli_dns)      s="فیلتر DNS (محتوای بزرگسال)" ;;
        fa:cli_zram)     s="سواپ فشرده zram" ;;
        fa:cli_swap)     s="فایل سواپ" ;;
        fa:cli_bbr)      s="BBR + fq" ;;
        fa:cli_core)     s="نوع کر xray" ;;
        fa:cli_list)     s="نمایش نودهای نصب‌شده" ;;
        fa:cli_rm)       s="حذف یک نود نصب‌شده" ;;
        fa:cli_start)    s="شروع نصب" ;;
        fa:cli_exit)     s="خروج" ;;
        fa:on_off)       s="روشن" ;;
        fa:off)          s="خاموش" ;;
        fa:cli_mem)      s="رم آزاد" ;;
        fa:cli_sw)       s="سواپ" ;;
        fa:cli_core_s)   s="هسته" ;;
        fa:cli_applied)  s="اعمال شد" ;;
        fa:cli_state)    s="وضعیت" ;;
        en:mode_q)       s="Start the install directly? (n = open the CLI to customise)" ;;
        en:cli_title)    s="CLI - customise this install" ;;
        en:cli_pick)     s="Pick an option" ;;
        en:cli_dns)      s="Filtered DNS (block adult content)" ;;
        en:cli_zram)     s="zram compressed swap" ;;
        en:cli_swap)     s="swap file" ;;
        en:cli_bbr)      s="BBR + fq" ;;
        en:cli_core)     s="xray core type" ;;
        en:cli_list)     s="list installed nodes" ;;
        en:cli_rm)       s="remove an installed node" ;;
        en:cli_start)    s="start the install" ;;
        en:cli_exit)     s="exit" ;;
        en:on_off)       s="on" ;;
        en:off)          s="off" ;;
        en:cli_mem)      s="RAM free" ;;
        en:cli_sw)       s="swap" ;;
        en:cli_core_s)   s="core" ;;
        en:cli_applied)  s="applied" ;;
        en:cli_state)    s="state" ;;
        en:node_name_q)  s="Panel node name (final format ip+name, Enter = auto): " ;;
        en:swap_q)       s="Create a swap file sized to this server's RAM (%sM)?" ;;
        en:zram_q)       s="Also add compressed swap in RAM (zram)?" ;;
        en:porn_q)       s="Block adult content with a filtered (Family) DNS?" ;;
        en:core_q)       s="Install the custom xray core (per-user connection tracker)?" ;;
        en:bbr_q)        s="Enable BBR + fq (better speed and stability on lossy links)?" ;;
        en:done)         s="PasarGuard node installed" ;;
        en:health)       s="Install health check" ;;
        en:uninstall_q)  s="Remove this node completely? Type the instance name (%s): " ;;
        *)               s="${key}" ;;
    esac
    # shellcheck disable=SC2059
    printf "$s" "$@"
}

# --------------------------------------------------------------------------
# Progress bar + summary box
# --------------------------------------------------------------------------
STEP_TOTAL=6

bar() {
    local n="$1" i out=""
    for ((i = 0; i < 10; i++)); do
        if [ "$i" -lt "$n" ]; then out+="█"; else out+="░"; fi
    done
    printf '%s' "$out"
}

step() {
    local n="$1"; shift
    local filled=$((n * 10 / STEP_TOTAL))
    printf '\033[1;35m[%s]\033[0m \033[1mStep %s/%s\033[0m %s\n' \
        "$(bar "$filled")" "$n" "$STEP_TOTAL" "$*"
}

BOX_W=62
box_top()  { printf '┌%s┐\n' "$(printf '─%.0s' $(seq 1 "$BOX_W"))"; }
box_sep()  { printf '├%s┤\n' "$(printf '─%.0s' $(seq 1 "$BOX_W"))"; }
box_bot()  { printf '└%s┘\n' "$(printf '─%.0s' $(seq 1 "$BOX_W"))"; }
box_row()  {
    local label="$1" value="${2:-}" text
    text="$(printf ' %-13s %s' "$label" "$value")"
    printf '│%-*s│\n' "$BOX_W" "$text"
}
box_text() {
    local text=" $1"
    printf '│%-*s│\n' "$BOX_W" "$text"
}


# --------------------------------------------------------------------------
# Swap helpers - size follows RAM: equal to RAM, clamped to 2G..8G.
# --------------------------------------------------------------------------
SWAP_FILE="/swapfile"

swap_size_mb() {
    local ram_mb mb
    if [ -n "${SWAP_SIZE_MB:-}" ]; then
        printf '%s\n' "$SWAP_SIZE_MB"
        return 0
    fi
    ram_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
    mb=$ram_mb
    [ "$mb" -lt 2048 ] && mb=2048
    [ "$mb" -gt 8192 ] && mb=8192
    printf '%s\n' "$mb"
}

# enable_swap - create + mount SWAP_FILE and persist it in /etc/fstab.
# Never fails the install: every problem is a warning.
enable_swap() {
    local mb avail_mb
    mb="$(swap_size_mb)"
    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        ok "Swap is already enabled; leaving it as is."
        return 0
    fi
    if [ -e "$SWAP_FILE" ]; then
        warn "${SWAP_FILE} already exists but is not active; skipping swap creation."
        return 0
    fi
    avail_mb="$(df -Pm / | awk 'NR==2{print $4}')"
    if [ "${avail_mb:-0}" -lt $((mb + 1024)) ]; then
        warn "Not enough free disk for ${mb}M swap (${avail_mb:-0}M free); skipping."
        return 0
    fi
    if ! fallocate -l "${mb}M" "$SWAP_FILE" 2>/dev/null; then
        dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$mb" status=none 2>/dev/null || {
            warn "Could not create ${SWAP_FILE}."
            rm -f "$SWAP_FILE"
            return 0
        }
    fi
    chmod 600 "$SWAP_FILE"
    if ! mkswap "$SWAP_FILE" >/dev/null 2>&1 || ! swapon "$SWAP_FILE" 2>/dev/null; then
        warn "Could not activate swap on ${SWAP_FILE}; removing it."
        rm -f "$SWAP_FILE"
        return 0
    fi
    ok "Swap enabled: ${mb}M at ${SWAP_FILE}."
    if ! grep -qE "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
        printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab 2>/dev/null \
            || warn "Could not add ${SWAP_FILE} to /etc/fstab; swap will not survive a reboot."
    fi
}

# --------------------------------------------------------------------------
# zram - compressed swap in RAM (fast, spares the disk). Optional.
# --------------------------------------------------------------------------
zram_size_mb() {
    local ram_mb mb
    ram_mb=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
    mb=$((ram_mb / 2))
    [ "$mb" -lt 512 ] && mb=512
    [ "$mb" -gt 4096 ] && mb=4096
    printf '%s\n' "$mb"
}

enable_zram() {
    local mb
    mb="${1:-$(zram_size_mb)}"
    if swapon --show=NAME 2>/dev/null | grep -q zram; then
        ok "zram swap is already active."
        return 0
    fi
    if ! modprobe zram 2>/dev/null; then
        log "zram module missing; trying linux-modules-extra..."
        apt-get install -y "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
        modprobe zram 2>/dev/null || {
            warn "zram is not available on this kernel; skipping compressed swap."
            return 0
        }
    fi
    cat > /usr/local/sbin/zram-swap.sh <<EOS
#!/bin/sh
set -e
modprobe zram
[ -e /dev/zram0 ] || exit 0
echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo none > /sys/block/zram0/comp_algorithm 2>/dev/null || true
echo ${mb}M > /sys/block/zram0/disksize
mkswap /dev/zram0 >/dev/null 2>&1 || true
swapon -p 100 /dev/zram0 2>/dev/null || true
EOS
    chmod 755 /usr/local/sbin/zram-swap.sh
    cat > /etc/systemd/system/zram-swap.service <<'EOS'
[Unit]
Description=zram compressed swap
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap.sh

[Install]
WantedBy=multi-user.target
EOS
    systemctl daemon-reload
    systemctl enable --now zram-swap >/dev/null 2>&1 || true
    if swapon --show=NAME 2>/dev/null | grep -q zram; then
        ok "zram swap enabled: ${mb}M (compressed, in RAM)."
    else
        warn "zram unit did not activate; continuing without compressed swap."
        systemctl disable --now zram-swap >/dev/null 2>&1 || true
    fi
}

# --------------------------------------------------------------------------
# Logs - cap journald and rotate node/xray logs so a chatty service cannot
# fill the disk (same failure we hit with gost on the Iranian servers).
# --------------------------------------------------------------------------
cap_journal() {
    install -d /etc/systemd/journald.conf.d 2>/dev/null || true
    cat > /etc/systemd/journald.conf.d/99-pg-node-deploy.conf <<'EOS'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOS
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    ok "journald capped at 200M."
}

setup_logrotate() {
    cat > /etc/logrotate.d/pg-node-deploy <<'EOS'
/var/log/pg-node/*.log /var/log/xray/*.log {
    size 50M
    rotate 2
    missingok
    notifempty
    copytruncate
}
EOS
    ok "logrotate rule written for node/xray logs."
}

# --------------------------------------------------------------------------
# Health check - what the operator actually needs to know after install.
# --------------------------------------------------------------------------
health_check() {
    local fails=0
    printf '\n'
    printf '\033[1;36m== %s ==\033[0m\n' "$(t health)"
    check_row() {
        local label="$1" state="$2"
        if [ "$state" = ok ]; then
            printf '  \033[1;32m[PASS]\033[0m %s\n' "$label"
        else
            printf '  \033[1;31m[FAIL]\033[0m %s\n' "$label"
            fails=$((fails + 1))
        fi
    }
    command -v ss >/dev/null 2>&1 || apt-get install -y iproute2 >/dev/null 2>&1 || true
    port_in_use "$SERVICE_PORT" && check_row "gRPC port ${SERVICE_PORT} listening" ok \
        || check_row "gRPC port ${SERVICE_PORT} listening" fail
    port_in_use "$API_PORT" && check_row "API port ${API_PORT} listening" ok \
        || check_row "API port ${API_PORT} listening" fail
    pgrep -f 'xray(-core)?/xray|/xray ' >/dev/null 2>&1 && check_row "xray process running" ok \
        || check_row "xray process running" fail
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^(${INSTANCE}|node)$" \
            && check_row "node container up" ok || check_row "node container up" fail
        # The panel polls the node (GetBaseInfo) every few seconds while it is
        # connected, so a recent success proves registration works end to end.
        local cname conn_label
        cname="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E "^(${INSTANCE}|node)$" | head -n1)"
        if [ "$LANG_CODE" = fa ]; then conn_label="اتصال نود به پنل"; else conn_label="node connected to the panel"; fi
        if [ -n "$cname" ]; then
            # The panel needs a few seconds to reach the node, so wait instead of
            # reporting a false failure right after the install.
            local waited=0 limit="${PANEL_WAIT_SECS:-60}"
            if ! docker logs --since 10m "$cname" 2>&1 | grep -q 'GetBaseInfo, Status: Success'; then
                printf '  \033[1;36m...\033[0m waiting up to %ss for the node to connect to the panel\n' "$limit"
                while [ "$waited" -lt "$limit" ]; do
                    sleep 3
                    waited=$((waited + 3))
                    docker logs --since 10m "$cname" 2>&1 | grep -q 'GetBaseInfo, Status: Success' && break
                done
            fi
            if docker logs --since 10m "$cname" 2>&1 | grep -q 'GetBaseInfo, Status: Success'; then
                check_row "$conn_label" ok
            else
                check_row "$conn_label" fail
            fi
        else
            check_row "$conn_label" fail
        fi
    else
        warn "docker not found; skipping container check."
    fi
    [ -s "$PG_ENV_FILE" ] && check_row "instance env file ${PG_ENV_FILE}" ok \
        || check_row "instance env file ${PG_ENV_FILE}" fail
    TcpRetransSegs="$(awk '/^TcpExt:/{for(i=1;i<=NF;i++) if($i=="TCPLostRetransmit") print $(i+1)}' /proc/net/netstat 2>/dev/null | head -1)"
    printf '  mem available : %s MB\n' "$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
    printf '  swap used     : %s\n' "$(free -m | awk '/Swap:/{print $3" / "$2" MB"}')"
    [ "${TcpRetransSegs:-0}" -gt 0 ] 2>/dev/null && printf '  lost retransmits (cumulative): %s\n' "$TcpRetransSegs"
    if [ "$fails" -eq 0 ]; then
        printf '\033[1;32m  all checks passed\033[0m\n\n'
    else
        printf '\033[1;33m  %s check(s) failed - see above\033[0m\n\n' "$fails"
    fi
    return 0
}

# --------------------------------------------------------------------------
# Uninstall - stop this instance and remove its files (asks for the name).
# --------------------------------------------------------------------------
do_uninstall() {
    local inst="$INSTANCE" ans
    [ -d "/opt/${inst}" ] || die "No instance '${inst}' found (expected /opt/${inst})."
    printf '\033[1;33m[?]\033[0m ' >&2
    t uninstall_q "$inst" >&2
    read -r ans || true
    [ "$ans" = "$inst" ] || die "Aborted (name did not match)."
    if command -v "$inst" >/dev/null 2>&1; then
        "$inst" down >/dev/null 2>&1 || true
        "$inst" service-stop >/dev/null 2>&1 || true
    fi
    systemctl disable --now "${inst}.service" >/dev/null 2>&1 || true
    if command -v docker >/dev/null 2>&1; then
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${inst}(-|$)" \
            | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
    rm -f "/etc/systemd/system/${inst}.service"
    rm -rf "/opt/${inst}" "/var/lib/${inst}" "/usr/local/bin/${inst}" "/root/${inst}-info.txt"
    systemctl daemon-reload 2>/dev/null || true
    ok "Instance '${inst}' removed."
    warn "Any leftover container (e.g. 'node') was not touched on purpose - check with: docker ps"
}

# --------------------------------------------------------------------------
# CLI mode - opened when the first question ("install directly?") is answered n.
# Lets the operator change the optional features (applied right away where it
# makes sense) or look after already installed nodes before the install runs.
# --------------------------------------------------------------------------
instance_names() {
    local d
    for d in /opt/*/; do
        [ -f "${d}.env" ] || continue
        basename "$d"
    done
}

list_instances() {
    local n any=0 state
    for n in $(instance_names); do
        any=1
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qE "^(${n}|node)$"; then state=up; else state=down; fi
        printf '  %-18s %s\n' "$n" "$state"
    done
    [ "$any" = 1 ] || printf '  (none)\n'
}

disable_zram() {
    systemctl disable --now zram-swap >/dev/null 2>&1 || true
    local d
    for d in /sys/block/zram*; do
        [ -e "${d}/disksize" ] || continue
        swapoff "/dev/$(basename "$d")" >/dev/null 2>&1 || true
    done
    ok "zram disabled."
}

pad_to() {  # <text> <width> - pads (or truncates) by characters, not bytes
    local text="$1" width="$2" n
    if [ "${#text}" -gt "$width" ]; then
        printf '%s' "${text:0:width}"
        return 0
    fi
    n=$(( width - ${#text} ))
    printf '%s%*s' "$text" "$n" ""
}

cli_item() {  # <num> <label> <state> <kind: on|off|push|exit>
    local num="$1" label="$2" state="$3" kind="${4:-push}" dot colour
    case "$kind" in
        on)   dot="●"; colour="1;32" ;;
        off)  dot="○"; colour="2;37" ;;
        push) dot="›"; colour="1;34" ;;
        exit) dot="×"; colour="2;37" ;;
    esac
    printf '│ \033[1;36m%s\033[0m \033[%sm%s\033[0m %s \033[%sm%s\033[0m\033[1;35m│\033[0m\n' \
        "$num" "$colour" "$dot" "$(pad_to "$label" 34)" "$colour" "$(pad_to "$state" 12)"
}

cli_status() {
    local mem sw core line
    mem="$(awk '/MemAvailable/{printf "%.1fG", $2/1048576}' /proc/meminfo)"
    sw="$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if (t>0) printf "%dM", (t-f)/1024; else printf "off"}' /proc/meminfo)"
    [ "${INSTALL_CUSTOM_CORE:-0}" = "1" ] && core="custom" || core="stock"
    line="$(t cli_mem): ${mem}  ·  $(t cli_sw): ${sw}  ·  $(t cli_core_s): ${core}"
    printf '│ \033[2m%s\033[0m \033[1;35m│\033[0m\n' "$(pad_to "$line" 50)"
}

cli_note() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

cli_menu_draw() {  # prints one menu frame; sets MENU_LINES
    local state kind frame
    frame="$( {
        printf '┌%s┐\n' "$(printf '─%.0s' $(seq 1 "$MENU_W"))"
        printf '│ \033[1;35m%s\033[0m\033[2m%s\033[0m \033[1;35m│\033[0m\n' \
            "$(pad_to "pg-node-deploy ${SCRIPT_VERSION}" 40)" "$(pad_to "${LANG_CODE}" 10)"
        printf '│ \033[2m%s\033[0m \033[1;35m│\033[0m\n' "$(pad_to "$(t cli_title)" 50)"
        printf '├%s┤\n' "$(printf '─%.0s' $(seq 1 "$MENU_W"))"
        if [ "${BLOCK_PORN:-0}" = "1" ]; then state="$(t on_off)"; kind=on; else state="$(t off)"; kind=off; fi
        cli_item 1 "$(t cli_dns)" "$state" "$kind"
        if [ "${ENABLE_ZRAM:-0}" = "1" ]; then state="$(t on_off)"; kind=on; else state="$(t off)"; kind=off; fi
        cli_item 2 "$(t cli_zram)" "$state" "$kind"
        if [ "${ENABLE_SWAP:-0}" = "1" ]; then state="$(t on_off)"; kind=on; else state="$(t off)"; kind=off; fi
        cli_item 3 "$(t cli_swap)" "$state" "$kind"
        if [ "${ENABLE_BBR:-1}" = "1" ]; then state="$(t on_off)"; kind=on; else state="$(t off)"; kind=off; fi
        cli_item 4 "$(t cli_bbr)" "$state" "$kind"
        if [ "${INSTALL_CUSTOM_CORE:-0}" = "1" ]; then state="custom"; kind=on; else state="stock"; kind=off; fi
        cli_item 5 "$(t cli_core)" "$state" "$kind"
        printf '├%s┤\n' "$(printf '─%.0s' $(seq 1 "$MENU_W"))"
        cli_item 6 "$(t cli_list)" "" push
        cli_item 7 "$(t cli_rm)" "" push
        cli_item 8 "$(t cli_start)" "" push
        cli_item 0 "$(t cli_exit)" "" exit
        printf '├%s┤\n' "$(printf '─%.0s' $(seq 1 "$MENU_W"))"
        cli_status
        printf '└%s┘\n' "$(printf '─%.0s' $(seq 1 "$MENU_W"))"
    } )"
    printf '%s\n' "$frame"
    MENU_LINES="$(printf '%s\n' "$frame" | wc -l)"
}

cli_menu() {
    local c state first=1
    MENU_W=52
    while :; do
        cli_menu_draw
        printf '\033[1;38;5;51m[?] %s:\033[0m ' "$(t cli_pick)"
        read -r c || c=0
        case "$c" in
            1)
                if [ "${BLOCK_PORN:-0}" = "1" ]; then
                    BLOCK_PORN=0; restore_default_dns || warn "DNS restore failed."
                else
                    BLOCK_PORN=1; configure_dns || warn "DNS setup failed."
                fi ;;
            2)
                if [ "${ENABLE_ZRAM:-0}" = "1" ]; then ENABLE_ZRAM=0; disable_zram
                else ENABLE_ZRAM=1; enable_zram || warn "zram setup failed."; fi ;;
            3)
                if [ "${ENABLE_SWAP:-0}" = "1" ]; then ENABLE_SWAP=0
                else ENABLE_SWAP=1; enable_swap || warn "swap setup failed."; fi ;;
            4)
                if [ "${ENABLE_BBR:-1}" = "1" ]; then ENABLE_BBR=0
                else ENABLE_BBR=1; enable_bbr_fq || true; fi ;;
            5)
                if [ "${INSTALL_CUSTOM_CORE:-0}" = "1" ]; then INSTALL_CUSTOM_CORE=0; else INSTALL_CUSTOM_CORE=1; fi
                # Apply to an existing node right away, otherwise the choice
                # only takes effect on the next install.
                inst="${INSTANCE:-}"
                [ -n "$inst" ] || inst="$(find_installed_instance || true)"
                if [ -n "$inst" ] && [ -f "/opt/${inst}/.env" ]; then
                    INSTANCE="$inst"
                    if [ "${INSTALL_CUSTOM_CORE}" = "1" ]; then
                        if install_custom_core; then cli_note "custom core applied to ${inst}"
                        else warn "custom core install failed"; fi
                    else
                        use_stock_core; cli_note "stock core restored for ${inst}"
                    fi
                    if command -v "$inst" >/dev/null 2>&1; then
                        "$inst" restart -n || warn "restart '${inst}' manually to load the core."
                    else
                        warn "restart '${inst}' manually to load the core."
                    fi
                fi ;;
            6) list_instances ;;
            7)
                list_instances
                printf '\033[1;38;5;203m[?] %s:\033[0m ' "instance name"
                read -r state || state=""
                if [ -n "$state" ] && [ -d "/opt/${state}" ]; then
                    INSTANCE="$state"; do_uninstall || true
                else
                    warn "No such instance: ${state:-<empty>}"
                fi ;;
            8) return 0 ;;
            0) exit 0 ;;
            *) warn "1-8 or 0" ;;
        esac
        # toggles redraw in place; actions that printed output redraw below
        case "$c" in
            1|2|3|4|5) printf '\033[%dA\033[J' "$(( MENU_LINES + 1 ))" ;;
        esac
    done
}


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

# Warm the resolver cache for the hosts the upstream installer hits with a
# 5s timeout and no retry (github.com). A cold first lookup is the usual
# killer: it takes 4-5s on flaky links and trips their --connect-timeout 5.
warm_github_dns() {
    local i
    for i in 1 2 3; do
        dns_resolves "github.com" || true
        dns_resolves "raw.githubusercontent.com" || true
    done
}

# Restore the DNS the server had before this installer touched it: the
# systemd-resolved stub when available, otherwise a plain 127.0.0.53.
restore_default_dns() {
    chattr -i /etc/resolv.conf 2>/dev/null || true
    # Prefer the copy saved before the first filtered-DNS write (and the
    # symlink target, when it was a systemd-resolved stub).
    if [ -s /etc/pg-node-deploy/resolv.conf.orig.link ]; then
        rm -f /etc/resolv.conf
        ln -sf "$(cat /etc/pg-node-deploy/resolv.conf.orig.link)" /etc/resolv.conf
        case "$(cat /etc/pg-node-deploy/resolv.conf.orig.link)" in
            *stub-resolv.conf)
                # Older runs wrote through the symlink, polluting the stub file.
                systemctl restart systemd-resolved >/dev/null 2>&1 || true ;;
        esac
        ok "DNS restored to the original symlink ($(cat /etc/pg-node-deploy/resolv.conf.orig.link))."
        return 0
    fi
    if [ -s /etc/pg-node-deploy/resolv.conf.orig ]; then
        cp -f /etc/pg-node-deploy/resolv.conf.orig /etc/resolv.conf
        ok "DNS restored from the copy saved before filtering (/etc/pg-node-deploy/resolv.conf.orig)."
        return 0
    fi
    if [ -e /run/systemd/resolve/stub-resolv.conf ]; then
        rm -f /etc/resolv.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
        systemctl restart systemd-resolved >/dev/null 2>&1 || true
        ok "DNS restored to the server default (systemd-resolved, 127.0.0.53)."
    elif systemctl is-active --quiet systemd-resolved; then
        printf 'nameserver 127.0.0.53\n' > /etc/resolv.conf
        warn "No systemd-resolved stub file; /etc/resolv.conf set to 127.0.0.53."
    else
        warn "No systemd-resolved here and no saved original; leaving /etc/resolv.conf untouched."
    fi
    sleep 1
}

configure_dns() {
    if [ "${SKIP_DNS_CONFIG:-0}" = "1" ]; then
        log "SKIP_DNS_CONFIG=1; leaving /etc/resolv.conf untouched."
        github_dns_ok || warn "Current DNS cannot resolve github.com; Step 4 may fail."
        return 0
    fi

    # The user said no to adult-content filtering: drop whatever DNS this
    # installer wrote earlier and go back to the system default (the
    # systemd-resolved stub, 127.0.0.53), unless CUSTOM_DNS was given.
    if [ "${BLOCK_PORN:-1}" = "0" ] && [ -z "${CUSTOM_DNS:-}" ]; then
        restore_default_dns
        github_dns_ok || warn "System-default DNS cannot resolve github.com; Step 4 may fail."
        return 0
    fi

    local candidates=()
    if [ -n "${CUSTOM_DNS:-}" ]; then
        # shellcheck disable=SC2206
        candidates+=(${CUSTOM_DNS})
    else
        # AdGuard Family (blocks adult content) first, then CleanBrowsing
        # Family and plain ad-blocking resolvers as fallbacks.
        candidates=("94.140.14.15" "94.140.15.16" "185.228.168.168" "185.228.169.168" "1.1.1.3" "8.8.8.8")
        # 127.0.0.53 (systemd stub) is only appended when the system was
        # using it before (symlink), because it breaks when resolv.conf is
        # no longer a symlink to /run/systemd/resolve/*.
    fi
    # Keep a copy of the untouched config so a later run can undo filtering.
    install -d -m 700 /etc/pg-node-deploy 2>/dev/null || true
    if [ ! -e /etc/pg-node-deploy/resolv.conf.orig ] && [ ! -e /etc/pg-node-deploy/resolv.conf.orig.link ]; then
        if [ -L /etc/resolv.conf ]; then
            readlink /etc/resolv.conf > /etc/pg-node-deploy/resolv.conf.orig.link 2>/dev/null || true
        else
            cp -f /etc/resolv.conf /etc/pg-node-deploy/resolv.conf.orig 2>/dev/null || true
        fi
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
    # Writing through the symlink would overwrite systemd-resolved's stub file.
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf

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

# Pre-seed the upstream pg-node.sh shared libraries with our resilient
# downloader. Upstream re-downloads these on EVERY run with a single
# `--connect-timeout 5` attempt and dies with "Missing shared library" when
# DNS flakes — but it KEEPS any existing copy in
# /usr/local/lib/pasarguard-scripts/lib. Seeding that copy first (from the
# fast raw.githubusercontent.com host, with retries) makes Step 4 immune to
# the 5s-timeout flake: worst case the upstream refresh fails and the seeded
# copy is used.
preseed_pg_node_libs() {
    local lib_dir="${1:-/usr/local/lib/pasarguard-scripts/lib}"
    local libs="common.sh system.sh docker.sh github.sh"
    local lib ok_count=0
    mkdir -p "$lib_dir" 2>/dev/null || warn "Cannot create ${lib_dir}; continuing anyway."
    for lib in $libs; do
        if robust_download "https://raw.githubusercontent.com/PasarGuard/scripts/main/lib/${lib}" "$lib_dir/$lib.tmp" \
        || robust_download "https://github.com/PasarGuard/scripts/raw/main/lib/${lib}" "$lib_dir/$lib.tmp"; then
            mv -f "$lib_dir/$lib.tmp" "$lib_dir/$lib" 2>/dev/null || true
            chmod 644 "$lib_dir/$lib" 2>/dev/null || true
        else
            rm -f "$lib_dir/$lib.tmp" 2>/dev/null || true
        fi
        if [ -s "$lib_dir/$lib" ]; then
            ok_count=$((ok_count + 1))
        fi
    done
    if [ "$ok_count" -eq 4 ]; then
        ok "Upstream shared libs ready in ${lib_dir} (4/4)."
        return 0
    fi
    warn "Only ${ok_count}/4 upstream shared libs available in ${lib_dir}."
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
# sysctl tuning - written as 09-node-tuning.conf so it loads BEFORE the
# panel's own files (e.g. zz-backpack.conf, which is loaded last), keeping the
# panel's aggressive network values (rmem/wmem, somaxconn, netdev_max_backlog,
# ip_local_port_range, ...). We only set here what the panel does not:
# tcp_mem, swappiness and file-max.
# --------------------------------------------------------------------------
NODE_TUNING_CONF="/etc/sysctl.d/09-node-tuning.conf"

tune_sysctl() {
    mkdir -p /etc/sysctl.d
    cat > "$NODE_TUNING_CONF" <<'EOF'
# Managed by pg-node-deploy - loads before the panel files (09 < 99/zz).
net.ipv4.tcp_mem = 65536 131072 262144
vm.swappiness = 10
fs.file-max = 1048576
EOF
    sysctl --system >/dev/null 2>&1 \
        || sysctl -p "$NODE_TUNING_CONF" >/dev/null 2>&1 \
        || warn "Could not apply ${NODE_TUNING_CONF}."
    ok "sysctl tuning written to ${NODE_TUNING_CONF} (tcp_mem, swappiness=10, file-max=1048576)."
}

# --------------------------------------------------------------------------
# BBR + fq (Step 3, optional) - keeps throughput through partial packet loss
# and removes bufferbloat, which is what makes new sessions lag on lossy Iran
# <-> Europe paths. Enter = yes in the prompt; ENABLE_BBR=0 skips it.
# --------------------------------------------------------------------------
BBR_CONF="/etc/sysctl.d/99-bbr-fq.conf"

enable_bbr_fq() {
    mkdir -p /etc/sysctl.d
    if ! cat > "$BBR_CONF" <<'EOF'
# Managed by pg-node-deploy - BBR congestion control + fq qdisc
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    then
        warn "Could not write ${BBR_CONF}; BBR will not survive a reboot."
    fi
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 \
        || warn "Could not set net.core.default_qdisc=fq."
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 \
        || warn "Could not set net.ipv4.tcp_congestion_control=bbr."
    local cc qd
    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [ "$cc" = "bbr" ]; then
        ok "BBR enabled (qdisc=${qd:-unknown}), persisted in ${BBR_CONF}."
    else
        warn "BBR is not active (current: ${cc:-unknown}); this kernel may not support it."
    fi
}

# --------------------------------------------------------------------------
# Disable IPv6 persistently (99zz loads last) so the custom xray core stops
# emitting IPv6 outbound-route noise (Ip6OutNoRoutes). The node is restarted
# after this so xray rebinds cleanly.
# --------------------------------------------------------------------------
NODE_IPV6_CONF="/etc/sysctl.d/99zz-node-disable-ipv6.conf"

disable_ipv6() {
    mkdir -p /etc/sysctl.d
    cat > "$NODE_IPV6_CONF" <<'EOF'
# Managed by pg-node-deploy - disable IPv6 persistently
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl --system >/dev/null 2>&1 || warn "Could not reload sysctl after disabling IPv6."
    # net.ipv6.conf.all only affects new interfaces; force it on existing ones too.
    local _f
    for _f in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
        [ -w "$_f" ] && echo 1 > "$_f" 2>/dev/null || true
    done
    ok "IPv6 disabled (${NODE_IPV6_CONF})."
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

# --------------------------------------------------------------------------
# xray core helpers - shared by the install flow and the CLI menu so a core
# choice toggled in the menu also applies to an already-installed node.
# --------------------------------------------------------------------------
detect_xray_arch() {
    local m
    m="$(uname -m 2>/dev/null || echo unknown)"
    case "$m" in
        x86_64|amd64) printf 'amd64\n'; return 0 ;;
        aarch64|arm64) printf 'arm64\n'; return 0 ;;
        *) return 1 ;;
    esac
}

core_env_file() { printf '/opt/%s/.env\n' "${INSTANCE:-$DEFAULT_INSTANCE}"; }
core_dir()      { printf '/var/lib/%s/xray-core\n' "${INSTANCE:-$DEFAULT_INSTANCE}"; }

use_stock_core() {
    local env_file
    env_file="$(core_env_file)"
    # Drop any custom path so the node falls back to its own /usr/local/bin/xray.
    [ -f "$env_file" ] && sed -i -E '/^XRAY_EXECUTABLE_PATH *=/d' "$env_file"
    return 0
}

install_custom_core() {
    local arch zip url dir env_file candidate
    dir="$(core_dir)"
    env_file="$(core_env_file)"
    command -v wget  >/dev/null 2>&1 || { apt-get update -y; apt-get install -y wget; }
    command -v unzip >/dev/null 2>&1 || { apt-get update -y; apt-get install -y unzip; }

    arch="$(detect_xray_arch)" \
        || die "Unsupported CPU architecture '$(uname -m)'. This installer supports x86_64 (amd64) and aarch64 (arm64) only."
    zip="xray-${arch}.zip"
    url="${XRAY_RELEASE_BASE}/${zip}"
    log "Detected CPU arch: $(uname -m) -> ${arch}; downloading ${zip} (${XRAY_VERSION})"

    if command -v curl >/dev/null 2>&1; then
        robust_download "$url" "$WORK_DIR/${zip}" || die "Failed to download xray core from $url"
    else
        wget --tries=3 --timeout=30 -O "$WORK_DIR/${zip}" "$url" || die "Failed to download xray core from $url"
    fi
    ok "Downloaded xray archive (${zip})."

    mkdir -p "$dir"
    cp -f "$WORK_DIR/${zip}" "$dir/"
    (
        cd "$dir" || exit 1
        unzip -o "$zip" >/dev/null
        if [ -f "xray-${arch}" ]; then
            mv -f "xray-${arch}" xray
        elif [ -f xray-amd64 ] && [ "$arch" = "amd64" ]; then
            mv -f xray-amd64 xray
        elif [ -f xray-arm64 ] && [ "$arch" = "arm64" ]; then
            mv -f xray-arm64 xray
        elif [ ! -f xray ]; then
            # Fall back to whatever single binary the archive shipped.
            candidate="$(find . -maxdepth 1 -type f -not -name '*.zip' | head -n1)"
            [ -n "$candidate" ] && mv -f "$candidate" xray
        fi
        chmod +x xray 2>/dev/null || true
    )

    [ -f "$dir/xray" ] || die "xray binary was not found after extraction."
    [ -f "$env_file" ] || die "Missing ${env_file}; is the node installed (instance ${INSTANCE:-$DEFAULT_INSTANCE})?"

    sed -i -E "s|^#? *XRAY_EXECUTABLE_PATH *=.*|XRAY_EXECUTABLE_PATH=${dir}/xray|" "$env_file"
    grep -q '^XRAY_EXECUTABLE_PATH=' "$env_file" || echo "XRAY_EXECUTABLE_PATH=${dir}/xray" >> "$env_file"
    ok "XRAY_EXECUTABLE_PATH set to ${dir}/xray"
}

# First instance that already has an env file (used when the menu applies a
# core choice before INSTANCE has been resolved).
find_installed_instance() {
    local d
    for d in /opt/*/.env; do
        [ -f "$d" ] || continue
        basename "$(dirname "$d")"
        return 0
    done
    return 1
}

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -r "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Temp dir is created before the prompts because the CLI menu (DNS toggle) uses it.
WORK_DIR="$(mktemp -d /tmp/pg-node-install.XXXXXX)"

# --------------------------------------------------------------------------
# First question: install straight away, or open the CLI to customise.
# Answer n (or CLI_MODE=1) to open the menu; it returns here when you choose
# "start the install".
# --------------------------------------------------------------------------
if [ -t 0 ] && [ "$ASSUME_YES" != "1" ] && [ -z "${CLI_MODE:-}" ]; then
    if ask_yn "$(t mode_q)" y "38;5;51"; then
        CLI_MODE=0
    else
        CLI_MODE=1
    fi
fi
if [ "${CLI_MODE:-0}" = "1" ]; then
    cli_menu
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
            printf '\033[1;38;5;220m[?] Press Enter to (re)install on it, or type a new instance name:\033[0m ' >&2
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

if [ "$UNINSTALL" = "1" ]; then
    do_uninstall
    exit 0
fi

if [ "$REPAIR" = "1" ] && [ ! -d "/opt/${INSTANCE}" ]; then
    warn "Nothing to repair at /opt/${INSTANCE}; running a fresh install instead."
fi

# --------------------------------------------------------------------------
# Panel node name - asked FIRST so the panel entry is ip+name.
# Final format: <server-ip>-<name> (custom instance appends -<instance>).
# Resolution order: NODE_NAME env (full) -> NODE_NAME_SUFFIX env -> interactive
# prompt (when a terminal is attached) -> auto (<IP>-<host4>-<datacenter>).
# Non-interactive runs never block: empty suffix means auto.
# --------------------------------------------------------------------------
NODE_NAME_SUFFIX="${NODE_NAME_SUFFIX:-}"
if [ -z "${NODE_NAME:-}" ] && [ -z "$NODE_NAME_SUFFIX" ] && [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
    printf '\033[1;38;5;177m[?] ' >&2
    t node_name_q >&2
    printf '\033[0m\n' >&2
    read -r NODE_NAME_SUFFIX || true
fi

# --------------------------------------------------------------------------
# Swap - asked right after the node name (Enter = yes). Sized from RAM (2G..8G).
# --yes turns it on; there is no prompt in non-interactive runs.
# --------------------------------------------------------------------------
if [ "$ASSUME_YES" = "1" ] && [ -z "${ENABLE_SWAP:-}" ]; then
    ENABLE_SWAP=1
fi
if [ -t 0 ] && [ "$ASSUME_YES" != "1" ] && [ -z "${ENABLE_SWAP:-}" ]; then
    if ask_yn "$(t swap_q "$(swap_size_mb)")" y "38;5;33"; then
        ENABLE_SWAP=1
    else
        ENABLE_SWAP=0
    fi
fi
if [ "${ENABLE_SWAP:-0}" = "1" ]; then
    enable_swap
fi

# Extra choices. Interactive: Enter = yes for every option (core included).
if [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
    if [ -z "${ENABLE_ZRAM:-}" ]; then
        if ask_yn "$(t zram_q)" y "38;5;45"; then
            ENABLE_ZRAM=1
        else
            ENABLE_ZRAM=0
        fi
    fi
    if [ -z "${BLOCK_PORN:-}" ]; then
        if ask_yn "$(t porn_q)" y 33; then
            BLOCK_PORN=1
        else
            BLOCK_PORN=0
        fi
    fi
    if [ -z "${INSTALL_CUSTOM_CORE:-}" ]; then
        if ask_yn "$(t core_q)" y "38;5;214"; then
            INSTALL_CUSTOM_CORE=1
        else
            INSTALL_CUSTOM_CORE=0
        fi
    fi
    if [ -z "${ENABLE_BBR:-}" ]; then
        if ask_yn "$(t bbr_q)" y "38;5;40"; then
            ENABLE_BBR=1
        else
            ENABLE_BBR=0
        fi
    fi
fi

# Non-interactive defaults.
ENABLE_ZRAM="${ENABLE_ZRAM:-1}"
BLOCK_PORN="${BLOCK_PORN:-1}"
INSTALL_CUSTOM_CORE="${INSTALL_CUSTOM_CORE:-1}"
ENABLE_BBR="${ENABLE_BBR:-1}"

if [ "$ENABLE_ZRAM" = "1" ]; then
    enable_zram
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

cleanup() { [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"; }
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
printf '\033[1;35m==> pg-node-deploy %s (%s) - instance: %s\033[0m\n' "$SCRIPT_VERSION" "$LANG_CODE" "$INSTANCE"

step 1 "apt update"
apt-get update -y || warn "apt-get update reported errors; continuing anyway."
ok "Package lists updated."

log "Installing nload (network traffic monitor)..."
if ! command -v nload >/dev/null 2>&1; then
    apt-get install -y nload >/dev/null 2>&1 || warn "Could not install nload; continuing anyway."
fi
command -v nload >/dev/null 2>&1 && ok "nload is installed." || warn "nload is not available."

# Keep logs from filling the disk (a chatty service once ate 56G on one host).
cap_journal
setup_logrotate

# --------------------------------------------------------------------------
# Step 2 - resolv.conf (verified, never break DNS)
# --------------------------------------------------------------------------
step 2 "configuring /etc/resolv.conf"
configure_dns

# --------------------------------------------------------------------------
# Step 3 - kernel tuning (sysctl + nf_conntrack, persistent)
# --------------------------------------------------------------------------
step 3 "tuning kernel (sysctl, BBR, limits)"

if [ "${ENABLE_BBR:-1}" = "1" ]; then
    enable_bbr_fq
fi

tune_sysctl
tune_conntrack

# --------------------------------------------------------------------------
# Step 4 - install pg-node
# --------------------------------------------------------------------------
step 4 "installing PasarGuard node"

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
    # Docker needs a moment to release the sockets; the upstream installer
    # refuses to start while the port is still bound.
    for _i in $(seq 1 10); do
        port_in_use "$SERVICE_PORT" || break
        sleep 2
    done
    if port_in_use "$SERVICE_PORT"; then
        OLD_SERVICE_PORT="$SERVICE_PORT"
        SERVICE_PORT="$(pick_free_port_except "$API_PORT")" \
            || die "Service port ${SERVICE_PORT} is still in use and no free port was found."
        warn "Port ${OLD_SERVICE_PORT} is still busy after stopping the instance; using ${SERVICE_PORT} instead."
        warn "Update the node port in the panel to ${SERVICE_PORT}."
    fi
    if port_in_use "$API_PORT" || [ "$API_PORT" = "$SERVICE_PORT" ]; then
        OLD_API_PORT="$API_PORT"
        API_PORT="$(pick_free_port_except "$SERVICE_PORT")" \
            || die "API port ${API_PORT} is still in use and no free port was found."
        warn "API port ${OLD_API_PORT} is still busy; using ${API_PORT} instead."
        warn "Update the node API port in the panel to ${API_PORT}."
    fi
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

# Seed the upstream libs with our resilient downloader + warm the resolver
# cache, so the installer's own 5s-timeout download cannot kill the run on
# flaky DNS (it keeps any existing copy and only dies when genuinely missing).
warm_github_dns
preseed_pg_node_libs || warn "Continuing without pre-seeded libs; the installer will attempt its own download."

INSTALL_ARGS=(install -y --service-port "$SERVICE_PORT" --api-port "$API_PORT")

# Rewrite a port inside INSTALL_ARGS after a retry picked a new one.
set_install_port() {
    local key="$1" value="$2" i
    for i in "${!INSTALL_ARGS[@]}"; do
        if [ "${INSTALL_ARGS[$i]}" = "--${key}-port" ]; then
            INSTALL_ARGS[$((i + 1))]="$value"
        fi
    done
}
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
INSTALL_RC=1
for INSTALL_ATTEMPT in 1 2 3; do
    set +e
    bash "$WORK_DIR/pg-node.sh" "${INSTALL_ARGS[@]}" 2>&1 \
        | tee "$WORK_DIR/install.log"
    INSTALL_RC="${PIPESTATUS[0]}"
    set -e
    if [ "$INSTALL_RC" -eq 0 ]; then
        break
    fi
    # Only this failure is safe to retry: the upstream lib download flaked
    # on its 5s timeout while DNS recovers. Anything else fails fast below
    # with the installer log.
    if grep -q "Missing shared library" "$WORK_DIR/install.log" && [ "$INSTALL_ATTEMPT" -lt 3 ]; then
        warn "Upstream lib download flaked (attempt ${INSTALL_ATTEMPT}/3); re-warming DNS and retrying..."
        warm_github_dns
        preseed_pg_node_libs || true
        sleep 3
        continue
    fi
    # Port got taken between our check and the install (or a docker container
    # still held it): move to a free port and try again.
    if grep -q "is already in use" "$WORK_DIR/install.log" && [ "$INSTALL_ATTEMPT" -lt 3 ]; then
        BUSY_PORT="$(grep -oE 'Port [0-9]+ is already in use' "$WORK_DIR/install.log" | grep -oE '[0-9]+' | head -n1)"
        if [ "$BUSY_PORT" = "$SERVICE_PORT" ]; then
            NEW_PORT="$(pick_free_port_except "$API_PORT")" || break
            warn "Service port ${SERVICE_PORT} was taken during install; retrying with ${NEW_PORT}."
            SERVICE_PORT="$NEW_PORT"
            set_install_port service "$NEW_PORT"
            continue
        elif [ "$BUSY_PORT" = "$API_PORT" ]; then
            NEW_PORT="$(pick_free_port_except "$SERVICE_PORT")" || break
            warn "API port ${API_PORT} was taken during install; retrying with ${NEW_PORT}."
            API_PORT="$NEW_PORT"
            set_install_port api "$NEW_PORT"
            continue
        fi
    fi
    break
done

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
# Step 4 - xray core
# Custom core is built from ImMohammad20000/Xray-core@UserConnTracker
# (per-user connection tracker: forced disconnect when quota is exhausted).
# Declining it leaves the core that ships with pg-node untouched.
# --------------------------------------------------------------------------
if [ "${INSTALL_CUSTOM_CORE:-0}" != "1" ]; then
    step 5 "keeping the stock xray core (custom core not selected)"
    use_stock_core
else
    step 5 "installing the custom xray core"
    install_custom_core
fi


# --------------------------------------------------------------------------
# Disable IPv6 (persistent) and restart the node so xray rebinds cleanly.
# --------------------------------------------------------------------------
log "Disabling IPv6 (persistent) ..."
disable_ipv6

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

# Colored terminal output: a summary box, then the copy-paste blocks.
box_top
box_text "$(t done)"
box_sep
box_row "Instance" "$INSTANCE"
box_row "Node name" "$NODE_NAME"
box_row "Server IP" "$SERVER_IP"
box_row "Service port" "$SERVICE_PORT"
box_row "API port" "$API_PORT"
box_row "Core" "$([ "${INSTALL_CUSTOM_CORE:-0}" = "1" ] && echo 'custom (per-user tracker)' || echo 'stock xray')"
box_row "Swap" "$(free -m | awk '/Swap:/{if ($2>0) print $2" MB"; else print "none"}')"
box_row "Info file" "$INFO_FILE"
box_bot

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

# --------------------------------------------------------------------------
# Final health check
# --------------------------------------------------------------------------
health_check || true

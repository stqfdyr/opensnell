#!/usr/bin/env bash
#
# OpenSnell server installer
#
# Subcommands:
#   install        Interactive install (default action)
#   reconfigure    Rewrite config interactively, restart service
#   update         Update binary in place
#   uninstall      Stop service + remove binary + (optional) remove config
#   start | stop | restart | enable | disable | status
#   info           Show connection details for the currently-installed server
#   help
#
# Without arguments, an interactive menu is shown.
#
# Two install variants:
#   1) OpenSnell (default, GPLv3, all-platform, this repo)
#   2) Surge official snell-server v5.0.1 (closed-source, Linux only)
#
# Project: https://github.com/missuo/opensnell
# SPDX-License-Identifier: GPL-3.0-or-later

set -uo pipefail

# ============================================================================
# Pretty-printing
# ============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

print_header()  { echo; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo -e "${BOLD}${BLUE}  $1${NC}"; echo -e "${BOLD}${BLUE}===========================================================${NC}"; echo; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

# ============================================================================
# Paths
# ============================================================================
INSTALL_BIN="/usr/local/bin/snell-server"
CONFIG_DIR="/etc/snell"
CONFIG_FILE="$CONFIG_DIR/snell-server.conf"
META_FILE="$CONFIG_DIR/.install_meta"
SERVICE_NAME="snell-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

OPENSNELL_REPO="missuo/opensnell"
OPENSNELL_RELEASE_API="https://api.github.com/repos/${OPENSNELL_REPO}/releases/latest"
SURGE_VERSION="v5.0.1"
SURGE_BASE_URL="https://dl.nssurge.com/snell"

# ============================================================================
# Preflight
# ============================================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "This script must be run as root (sudo bash install.sh ...)."
        exit 1
    fi
}

# This installer is Linux-only: it depends on systemd for service
# management, iptables/UFW/firewalld for the port hole-punch, and
# /etc/sysctl.conf for TFO. Anything else is out of scope — call out
# the alternatives early instead of failing halfway through.
check_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        print_error "This installer is Linux-only."
        print_info  "Detected OS: $(uname -s) — not supported."
        print_info  "On macOS / Windows / *BSD, build from source instead:"
        print_info  "    go install github.com/missuo/opensnell/cmd/snell-server@latest"
        print_info  "and configure / supervise it with your platform's native tooling"
        print_info  "(launchd, NSSM, rc.d, etc.). The OpenSnell server itself is"
        print_info  "cross-platform; only this installer is Linux-specific."
        exit 1
    fi
}

detect_arch_opensnell() {
    case "$(uname -m)" in
        x86_64)         echo "amd64"  ;;
        aarch64|arm64)  echo "arm64"  ;;
        i386|i686)      echo "386"    ;;
        armv7l|armv7)   echo "armv7"  ;;
        *) print_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
}

detect_arch_surge() {
    case "$(uname -m)" in
        x86_64)         echo "amd64"   ;;
        aarch64|arm64)  echo "aarch64" ;;
        i386|i686)      echo "i386"    ;;
        armv7l|armv7)   echo "armv7l"  ;;
        *) print_error "Surge official binary not available for $(uname -m)."; exit 1 ;;
    esac
}

ensure_tools() {
    # unzip only needed for the Surge variant. curl/openssl/ss are core.
    local missing=()
    for t in curl unzip openssl ss; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        print_info "Installing missing tools: ${missing[*]}"
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y "${missing[@]}" || {
                print_error "Failed to install: ${missing[*]}"; exit 1; }
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y "${missing[@]}" || { print_error "Failed to install"; exit 1; }
        elif command -v yum >/dev/null 2>&1; then
            yum install -y "${missing[@]}" || { print_error "Failed to install"; exit 1; }
        else
            print_error "Unsupported package manager. Install manually: ${missing[*]}"
            exit 1
        fi
    fi
}

# ============================================================================
# Helpers
# ============================================================================
gen_psk() { openssl rand -base64 18 | tr -d '/+=' | cut -c1-24; }

# Pick a free random port in [10000, 60000] that's not occupied (TCP + UDP).
pick_free_port() {
    local p
    for _ in $(seq 1 50); do
        p=$(( RANDOM % 50000 + 10000 ))
        if ! ss -lnt -lnu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]$p\$"; then
            echo "$p"; return 0
        fi
    done
    print_error "Could not find a free port after 50 tries"
    return 1
}

get_ipv4() {
    curl -s -4 --max-time 5 ifconfig.me 2>/dev/null \
        || curl -s -4 --max-time 5 ip.sb 2>/dev/null \
        || curl -s -4 --max-time 5 ipinfo.io/ip 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

# Make sure the kernel has TFO fully enabled (bit 0 + bit 1 = 3).
# If the running kernel already reports 3, we DON'T touch the user's
# system — we only write `tfo = true` to opensnell.conf and trust the
# kernel. We only edit /etc/sysctl.conf when the kernel is missing one
# of the bits, and even then we keep the edit minimal (sed-or-append).
enable_tfo_sysctl() {
    local current
    current=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "")

    if [ "$current" = "3" ]; then
        print_info "Kernel net.ipv4.tcp_fastopen=3 already; no system changes needed"
        return 0
    fi

    print_warning "Kernel net.ipv4.tcp_fastopen=${current:-unknown} (TFO needs 3)"
    local confirm
    confirm=$(prompt_yesno "Set it to 3 (will write to /etc/sysctl.conf and apply via sysctl -p)" "y")
    if [ "$confirm" != "y" ]; then
        print_warning "Skipping; OpenSnell will still set the socket option, but TFO won't actually take effect"
        return 0
    fi

    local sysctl_conf="/etc/sysctl.conf"
    local setting="net.ipv4.tcp_fastopen = 3"
    if [ -f "$sysctl_conf" ] && grep -qE '^[[:space:]]*net\.ipv4\.tcp_fastopen' "$sysctl_conf"; then
        sed -i "s|^[[:space:]]*net\.ipv4\.tcp_fastopen.*|$setting|" "$sysctl_conf"
        print_success "Updated existing entry in $sysctl_conf"
    else
        echo "$setting" >> "$sysctl_conf"
        print_success "Appended to $sysctl_conf"
    fi

    if sysctl -p >/dev/null 2>&1; then
        local after
        after=$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "?")
        if [ "$after" = "3" ]; then
            print_success "Kernel now reports net.ipv4.tcp_fastopen=3"
        else
            print_warning "sysctl -p ran but kernel reports tcp_fastopen=$after (expected 3)"
        fi
    else
        print_warning "sysctl -p failed; reboot or run it manually to apply"
    fi
}

get_installed_version() {
    [ -f "$META_FILE" ] && grep '^version=' "$META_FILE" | cut -d= -f2 || true
}

get_install_variant() {
    [ -f "$META_FILE" ] && grep '^variant=' "$META_FILE" | cut -d= -f2 || true
}

prompt_default() {
    # prompt_default "Question" "default" -> echoes user input or default
    local question="$1" default="$2" reply
    if [ -n "$default" ]; then
        read -r -p "$(echo -e "${CYAN}${question} [${BOLD}${default}${NC}${CYAN}]: ${NC}")" reply
    else
        read -r -p "$(echo -e "${CYAN}${question}: ${NC}")" reply
    fi
    echo "${reply:-$default}"
}

prompt_yesno() {
    # prompt_yesno "Question" "y" -> echoes "y" or "n"
    local question="$1" default="$2" reply
    read -r -p "$(echo -e "${CYAN}${question} (y/n) [${BOLD}${default}${NC}${CYAN}]: ${NC}")" reply
    reply="${reply:-$default}"
    case "${reply,,}" in y|yes) echo "y" ;; *) echo "n" ;; esac
}

# ============================================================================
# Download + install binary
# ============================================================================
download_opensnell() {
    print_header "Downloading OpenSnell"
    mkdir -p "$CONFIG_DIR"
    local arch tag url
    arch=$(detect_arch_opensnell)
    tag=$(curl -fsSL "$OPENSNELL_RELEASE_API" | grep '"tag_name":' | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
    if [ -z "$tag" ]; then
        print_error "Could not resolve latest release from GitHub API."
        print_info "Build from source instead: go install github.com/${OPENSNELL_REPO}/cmd/snell-server@latest"
        exit 1
    fi
    # The release publishes raw, per-target binaries — no archive wrapper.
    # Linux assets are unsuffixed; Windows ones end in .exe but we don't
    # consume those here (this installer is Linux-only by design).
    url="https://github.com/${OPENSNELL_REPO}/releases/download/${tag}/snell-server-linux-${arch}"

    print_info "Variant:      OpenSnell (self-hosted, GPLv3)"
    print_info "Architecture: linux/${arch}"
    print_info "Version:      ${tag}"
    print_info "Source:       ${url}"

    local tmp; tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    if ! curl -fL --progress-bar -o "$tmp" "$url"; then
        print_error "Download failed."
        print_info "If this is the first release, the GitHub Actions build may not have produced binaries yet."
        print_info "You can also build from source: go install github.com/${OPENSNELL_REPO}/cmd/snell-server@latest"
        exit 1
    fi
    install -m 0755 "$tmp" "$INSTALL_BIN"
    print_success "Installed OpenSnell ${tag} → ${INSTALL_BIN}"

    echo "variant=opensnell" >  "$META_FILE.tmp"
    echo "version=$tag"      >> "$META_FILE.tmp"
}

download_surge() {
    print_header "Downloading Surge official snell-server"
    mkdir -p "$CONFIG_DIR"
    local arch url workdir
    arch=$(detect_arch_surge)
    url="${SURGE_BASE_URL}/snell-server-${SURGE_VERSION}-linux-${arch}.zip"

    print_info "Variant:      Surge official (closed-source, Linux only)"
    print_info "Architecture: linux/${arch}"
    print_info "Version:      ${SURGE_VERSION}"
    print_info "Source:       ${url}"
    print_warning "By proceeding you accept Surge's license terms."

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    if ! curl -fL --progress-bar -o "$workdir/snell.zip" "$url"; then
        print_error "Download failed from $url"
        exit 1
    fi
    unzip -q "$workdir/snell.zip" -d "$workdir"
    install -m 0755 "$workdir/snell-server" "$INSTALL_BIN"
    print_success "Installed Surge snell-server ${SURGE_VERSION} → ${INSTALL_BIN}"

    echo "variant=surge"             >  "$META_FILE.tmp"
    echo "version=${SURGE_VERSION}"  >> "$META_FILE.tmp"
}

# ============================================================================
# Interactive config builder
# ============================================================================
build_config() {
    # Prefer the variant set during the immediately-preceding download (we
    # haven't committed META_FILE yet), or fall back to existing meta on
    # reconfigure.
    local variant=""
    if [ -f "$META_FILE.tmp" ]; then
        variant=$(grep '^variant=' "$META_FILE.tmp" | cut -d= -f2)
    elif [ -f "$META_FILE" ]; then
        variant=$(grep '^variant=' "$META_FILE" | cut -d= -f2)
    fi
    variant="${variant:-opensnell}"

    print_header "Snell server configuration"
    mkdir -p "$CONFIG_DIR"

    # --- Port ---
    local default_port port
    default_port=$(pick_free_port)
    port=$(prompt_default "Listen port (leave blank for a random free port)" "$default_port")
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "Invalid port: $port"; exit 1
    fi

    # --- PSK ---
    local psk
    psk=$(prompt_default "PSK / shared secret (leave blank to auto-generate)" "")
    if [ -z "$psk" ]; then
        psk=$(gen_psk)
        print_info "Generated PSK: ${BOLD}${psk}${NC}"
    fi

    # --- obfs ---
    local obfs
    obfs=$(prompt_default "obfs mode (off/http/tls)" "off")
    case "$obfs" in off|http|tls) ;; *) print_error "obfs must be one of: off, http, tls"; exit 1 ;; esac

    # --- ipv6 ---
    local ipv6_choice ipv6
    ipv6_choice=$(prompt_yesno "Allow IPv6 destinations (server-side outbound)" "y")
    if [ "$ipv6_choice" = "y" ]; then ipv6="true"; else ipv6="false"; fi

    # OpenSnell-only knobs
    local udp="true" quic="true" egress="" tfo="false"
    if [ "$variant" = "opensnell" ]; then
        local udp_choice quic_choice tfo_choice
        udp_choice=$(prompt_yesno "Accept UDP-over-TCP (snell datagram protocol)" "y")
        [ "$udp_choice" = "n" ] && udp="false"

        quic_choice=$(prompt_yesno "Enable QUIC proxy mode (UDP on the same port; required for Surge HTTP/3)" "y")
        [ "$quic_choice" = "n" ] && quic="false"

        egress=$(prompt_default "Egress interface to pin upstream sockets to (leave blank for default route)" "")

        tfo_choice=$(prompt_yesno "Enable TCP Fast Open (saves 1 RTT per fresh connection; Linux only)" "n")
        [ "$tfo_choice" = "y" ] && tfo="true"
    fi

    # --- Write config ---
    cat > "$CONFIG_FILE" <<EOF
[snell-server]
listen = 0.0.0.0:${port}
psk = ${psk}
obfs = ${obfs}
ipv6 = ${ipv6}
EOF
    if [ "$variant" = "opensnell" ]; then
        cat >> "$CONFIG_FILE" <<EOF
udp = ${udp}
quic = ${quic}
egress-interface = ${egress}
tfo = ${tfo}
EOF
    fi

    # Surge has its own per-proxy tfo=true, which our snell-server happily
    # ignores when running as the Surge variant. So TFO config is OpenSnell-only.
    if [ "$variant" = "opensnell" ] && [ "$tfo" = "true" ]; then
        enable_tfo_sysctl
    fi
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration written to $CONFIG_FILE"

    # --- Persist meta ---
    if [ -f "$META_FILE.tmp" ]; then mv "$META_FILE.tmp" "$META_FILE"; fi
    {
        grep -v '^\(port\|psk\|obfs\|ipv6\)=' "$META_FILE" 2>/dev/null || true
        echo "port=$port"
        echo "psk=$psk"
        echo "obfs=$obfs"
        echo "ipv6=$ipv6"
    } > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
    chmod 600 "$META_FILE"
}

# ============================================================================
# systemd unit
# ============================================================================
write_systemd_unit() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Snell server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_BIN} -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_success "systemd unit installed → $SERVICE_FILE"
}

# ============================================================================
# Firewall
# ============================================================================
configure_firewall() {
    [ -f "$META_FILE" ] || return 0
    local port quic
    port=$(grep '^port=' "$META_FILE" | cut -d= -f2)
    [ -z "$port" ] && return 0
    quic=$(grep -E '^quic\s*=' "$CONFIG_FILE" 2>/dev/null | awk -F= '{gsub(/ /,"",$2); print $2}')

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        print_info "UFW detected; allowing $port"
        ufw allow "${port}/tcp" >/dev/null 2>&1 || true
        [ "$quic" = "true" ] && ufw allow "${port}/udp" >/dev/null 2>&1 || true
        print_success "UFW: TCP/${port}${quic:+ + UDP/${port}} opened"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        print_info "firewalld detected; allowing $port"
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
        [ "$quic" = "true" ] && firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        print_success "firewalld: TCP/${port}${quic:+ + UDP/${port}} opened"
    else
        print_info "No firewall manager active; skipping firewall configuration"
    fi
}

# ============================================================================
# Service lifecycle
# ============================================================================
start_service()   { systemctl start   "$SERVICE_NAME" && print_success "Service started";   }
stop_service()    { systemctl stop    "$SERVICE_NAME" && print_success "Service stopped";   }
restart_service() { systemctl restart "$SERVICE_NAME" && print_success "Service restarted"; }
enable_service()  { systemctl enable  "$SERVICE_NAME" >/dev/null 2>&1 && print_success "Service enabled (auto-start on boot)"; }
disable_service() { systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 && print_success "Service disabled"; }
status_service()  {
    print_header "Service Status"
    systemctl status "$SERVICE_NAME" --no-pager 2>&1 | head -15 || true
}

# ============================================================================
# Connection info
# ============================================================================
show_info() {
    if [ ! -f "$META_FILE" ]; then
        print_warning "No installation metadata found; is the server installed?"
        return 1
    fi
    local variant version port psk obfs ipv6 ip
    variant=$(grep '^variant=' "$META_FILE" | cut -d= -f2)
    version=$(grep '^version=' "$META_FILE" | cut -d= -f2)
    port=$(grep    '^port='    "$META_FILE" | cut -d= -f2)
    psk=$(grep     '^psk='     "$META_FILE" | cut -d= -f2)
    obfs=$(grep    '^obfs='    "$META_FILE" | cut -d= -f2)
    ipv6=$(grep    '^ipv6='    "$META_FILE" | cut -d= -f2)
    ip=$(get_ipv4)

    print_header "Connection Info"
    echo -e "${BOLD}Variant:${NC}      ${variant} (${version})"
    echo -e "${BOLD}Server IP:${NC}    ${ip}"
    echo -e "${BOLD}Port:${NC}         ${port}"
    echo -e "${BOLD}PSK:${NC}          ${psk}"
    echo -e "${BOLD}obfs:${NC}         ${obfs}"
    echo -e "${BOLD}IPv6 egress:${NC}  ${ipv6}"

    print_header "Surge proxy config"
    local quic_flag=""
    [ "$variant" = "opensnell" ] && quic_flag=", block-quic=off"
    [ "$variant" = "surge"     ] && quic_flag=", block-quic=off"
    echo -e "${GREEN}my-snell = snell, ${ip}, ${port}, psk=${psk}, version=5, tfo=true${quic_flag}${NC}"

    print_header "Service"
    systemctl is-active --quiet "$SERVICE_NAME" \
        && print_success "snell-server is running" \
        || print_warning "snell-server is NOT running (try: systemctl start $SERVICE_NAME)"
}

# ============================================================================
# Top-level actions
# ============================================================================
do_install() {
    check_root; ensure_tools

    print_header "OpenSnell server installer"
    echo -e "${BOLD}Choose a variant:${NC}"
    echo -e "${GREEN}1)${NC} OpenSnell ${YELLOW}(default, GPLv3, all-platform)${NC}"
    echo -e "${GREEN}2)${NC} Surge official snell-server v5.0.1 ${YELLOW}(closed-source, Linux only)${NC}"
    echo
    read -r -p "$(echo -e "${CYAN}Variant [${BOLD}1${NC}${CYAN}]: ${NC}")" variant_choice
    case "${variant_choice:-1}" in
        1) download_opensnell ;;
        2) download_surge     ;;
        *) print_error "Invalid choice"; exit 1 ;;
    esac

    build_config
    write_systemd_unit
    configure_firewall
    enable_service
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "Service is running"
    else
        print_warning "Service is NOT running yet — check 'journalctl -u $SERVICE_NAME -n 30'"
    fi
    show_info
}

do_reconfigure() {
    check_root
    [ -f "$INSTALL_BIN" ] || { print_error "Binary not found; install first."; exit 1; }
    build_config
    write_systemd_unit
    configure_firewall
    restart_service
    show_info
}

do_update() {
    check_root; ensure_tools
    local variant; variant=$(get_install_variant)
    [ -z "$variant" ] && variant="opensnell"
    print_info "Updating variant: $variant"
    if [ "$variant" = "surge" ]; then
        download_surge
    else
        download_opensnell
    fi
    # Merge variant/version from .tmp into existing meta
    if [ -f "$META_FILE.tmp" ]; then
        local newver; newver=$(grep '^version=' "$META_FILE.tmp" | cut -d= -f2)
        sed -i.bak "s/^version=.*/version=${newver}/" "$META_FILE" 2>/dev/null || true
        rm -f "$META_FILE.tmp" "$META_FILE.bak"
    fi
    restart_service
    print_success "Update complete"
}

do_uninstall() {
    check_root
    print_warning "This will stop the service and remove the binary."
    local rm_cfg confirm
    confirm=$(prompt_yesno "Continue?" "n")
    [ "$confirm" != "y" ] && { print_info "Aborted."; return; }
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$INSTALL_BIN"
    print_success "Removed binary and service unit"
    rm_cfg=$(prompt_yesno "Also remove $CONFIG_DIR (configuration + PSK)?" "n")
    if [ "$rm_cfg" = "y" ]; then
        rm -rf "$CONFIG_DIR"
        print_success "Removed $CONFIG_DIR"
    else
        print_info "Configuration kept at $CONFIG_DIR"
    fi
}

# ============================================================================
# CLI
# ============================================================================
show_help() {
    cat <<EOF
OpenSnell server installer

Usage: $0 <subcommand>

Subcommands:
  install        Interactive install (default action when run without args)
  reconfigure    Rewrite the snell-server.conf interactively, restart service
  update         Re-download the binary, restart service
  uninstall      Stop service + remove binary (+ optionally remove config)
  start | stop | restart | enable | disable | status
  info           Print server IP / port / PSK / Surge config snippet
  help           Show this help

Interactive menu is shown when no subcommand is given.
EOF
}

show_menu() {
    echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
    echo -e "${BOLD}${MAGENTA}        OpenSnell Server Management Script           ${NC}"
    echo -e "${BOLD}${MAGENTA}=====================================================${NC}"
    echo
    echo -e "${GREEN}1)${NC}  Install"
    echo -e "${GREEN}2)${NC}  Reconfigure"
    echo -e "${GREEN}3)${NC}  Update binary"
    echo -e "${RED}4)${NC}  Uninstall"
    echo -e "${BLUE}5)${NC}  Start"
    echo -e "${BLUE}6)${NC}  Stop"
    echo -e "${BLUE}7)${NC}  Restart"
    echo -e "${CYAN}8)${NC}  Enable auto-start"
    echo -e "${CYAN}9)${NC}  Disable auto-start"
    echo -e "${YELLOW}10)${NC} Show status"
    echo -e "${YELLOW}11)${NC} Show connection info"
    echo -e "${MAGENTA}0)${NC}  Exit"
    echo
    read -r -p "$(echo -e "${CYAN}Enter your choice (0-11): ${NC}")" choice
    case "$choice" in
        1)  do_install        ;;
        2)  do_reconfigure    ;;
        3)  do_update         ;;
        4)  do_uninstall      ;;
        5)  start_service     ;;
        6)  stop_service      ;;
        7)  restart_service   ;;
        8)  enable_service    ;;
        9)  disable_service   ;;
        10) status_service    ;;
        11) show_info         ;;
        0)  print_info "Bye."; exit 0 ;;
        *)  print_error "Invalid option"; exit 1 ;;
    esac
}

main() {
    # `help` is the only subcommand that should work anywhere; everything
    # else needs systemd / iptables / sysctl etc., so refuse non-Linux
    # immediately rather than fail halfway through.
    case "${1:-}" in
        help|--help|-h) show_help; return ;;
    esac
    check_linux

    case "${1:-}" in
        install)        do_install        ;;
        reconfigure)    do_reconfigure    ;;
        update|upgrade) do_update         ;;
        uninstall)      do_uninstall      ;;
        start)          check_root; start_service     ;;
        stop)           check_root; stop_service      ;;
        restart)        check_root; restart_service   ;;
        enable)         check_root; enable_service    ;;
        disable)        check_root; disable_service   ;;
        status)         status_service                ;;
        info)           show_info                     ;;
        "")             show_menu                     ;;
        *)              print_error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@"

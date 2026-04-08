#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Snell Server Auto-Setup Script
# One-command deployment on Ubuntu / Debian
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/yxwuxing/snell-auto-setup/main/install.sh)
# ============================================================

SNELL_VERSION="v5.0.1"
CONF_PATH="/etc/snell-server.conf"
SERVICE_PATH="/lib/systemd/system/snell.service"
BIN_PATH="/usr/local/bin/snell-server"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Root check ───────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Please run as root: sudo bash $0"

# ── OS check ─────────────────────────────────────────────────
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "Cannot detect OS. /etc/os-release not found."
    fi
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"ubuntu"* && "$ID_LIKE" != *"debian"* ]]; then
        err "Unsupported OS: $PRETTY_NAME. This script supports Ubuntu/Debian only."
    fi
    info "OS detected: $PRETTY_NAME (${VERSION_ID:-unknown})"
}

# ── Architecture detection ───────────────────────────────────
detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)       ARCH="amd64" ;;
        i386|i686)    ARCH="i386" ;;
        aarch64)      ARCH="aarch64" ;;
        armv7l)       ARCH="armv7l" ;;
        *)            err "Unsupported architecture: $arch" ;;
    esac
    info "Architecture: $arch -> snell-server-${SNELL_VERSION}-linux-${ARCH}"
}

# ── Generate random port (1024-65535) ────────────────────────
random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        # Make sure the port is not in use
        if ! ss -tlnp | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# ── Generate random PSK (32 chars, base64-safe) ──────────────
random_psk() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

# ── Check existing installation ──────────────────────────────
# Sets: EXISTING_VERSION, NEED_DOWNLOAD, NEED_CONFIG
check_existing() {
    EXISTING_VERSION=""
    NEED_DOWNLOAD=true
    NEED_CONFIG=true

    # Check if binary exists
    if [[ -f "$BIN_PATH" ]]; then
        # Try to get version from the binary
        EXISTING_VERSION=$("$BIN_PATH" --version 2>/dev/null | grep -oP 'v[\d.]+' || echo "unknown")
        info "Existing snell-server found: ${EXISTING_VERSION}"

        if [[ "$EXISTING_VERSION" == "$SNELL_VERSION" ]]; then
            info "Already at target version ${SNELL_VERSION}, skipping download"
            NEED_DOWNLOAD=false
        else
            warn "Installed: ${EXISTING_VERSION} -> upgrading to ${SNELL_VERSION}"
            # Stop service before upgrading binary
            systemctl stop snell 2>/dev/null || true
        fi
    fi

    # Check if config exists — preserve port & PSK on reinstall/upgrade
    if [[ -f "$CONF_PATH" ]]; then
        local existing_port existing_psk
        existing_port=$(grep -oP '(?<=::0:)\d+' "$CONF_PATH" 2>/dev/null || true)
        existing_psk=$(grep -oP '(?<=psk = ).+' "$CONF_PATH" 2>/dev/null || true)

        if [[ -n "$existing_port" && -n "$existing_psk" ]]; then
            PORT="$existing_port"
            PSK="$existing_psk"
            NEED_CONFIG=false
            ok "Existing config preserved (port: ${PORT}, psk: ${PSK:0:6}...)"
        fi
    fi
}

# ── Install dependencies ─────────────────────────────────────
install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq wget unzip openssl > /dev/null 2>&1
    ok "Dependencies installed"
}

# ── Download & install Snell server ──────────────────────────
install_snell() {
    if [[ "$NEED_DOWNLOAD" == false ]]; then
        return
    fi

    local url="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${ARCH}.zip"
    local tmpdir
    tmpdir=$(mktemp -d)

    info "Downloading snell-server ${SNELL_VERSION}..."
    wget -q --show-progress -O "${tmpdir}/snell-server.zip" "$url" \
        || err "Download failed. Check network or URL: $url"

    info "Installing to ${BIN_PATH}..."
    unzip -o -q "${tmpdir}/snell-server.zip" -d "${tmpdir}"
    install -m 755 "${tmpdir}/snell-server" "$BIN_PATH"
    rm -rf "$tmpdir"

    ok "snell-server ${SNELL_VERSION} installed at ${BIN_PATH}"
}

# ── Generate config ──────────────────────────────────────────
generate_config() {
    if [[ "$NEED_CONFIG" == false ]]; then
        return
    fi

    PORT=$(random_port)
    PSK=$(random_psk)

    cat > "$CONF_PATH" <<EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
dns = 1.1.1.1, 8.8.8.8, 2001:4860:4860::8888
EOF

    chmod 600 "$CONF_PATH"
    ok "Config written to ${CONF_PATH}"
}

# ── Create systemd service ───────────────────────────────────
create_service() {
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${BIN_PATH} -c ${CONF_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable snell > /dev/null 2>&1
    systemctl restart snell
    ok "systemd service created and started"
}

# ── Firewall configuration ───────────────────────────────────
configure_firewall() {
    info "Checking firewall status..."

    # --- ufw ---
    if command -v ufw &> /dev/null; then
        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1)
        if [[ "$ufw_status" == *"active"* ]]; then
            info "ufw is active, opening port ${PORT}/tcp and ${PORT}/udp..."
            ufw allow "${PORT}/tcp" > /dev/null 2>&1
            ufw allow "${PORT}/udp" > /dev/null 2>&1
            ok "ufw: port ${PORT} opened (tcp+udp)"
        else
            info "ufw is installed but inactive, skipping"
        fi
    fi

    # --- firewalld ---
    if command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld 2>/dev/null; then
            info "firewalld is active, opening port ${PORT}..."
            firewall-cmd --permanent --add-port="${PORT}/tcp" > /dev/null 2>&1
            firewall-cmd --permanent --add-port="${PORT}/udp" > /dev/null 2>&1
            firewall-cmd --reload > /dev/null 2>&1
            ok "firewalld: port ${PORT} opened (tcp+udp)"
        fi
    fi

    # --- iptables (no ufw/firewalld) ---
    if ! command -v ufw &> /dev/null && ! command -v firewall-cmd &> /dev/null; then
        if command -v iptables &> /dev/null; then
            local rule_count
            rule_count=$(iptables -L INPUT --line-numbers 2>/dev/null | wc -l)
            if [[ "$rule_count" -gt 3 ]]; then
                info "iptables rules detected, adding port ${PORT}..."
                iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
                iptables -I INPUT -p udp --dport "${PORT}" -j ACCEPT 2>/dev/null || true
                # Persist with iptables-save if available
                if command -v iptables-save &> /dev/null; then
                    iptables-save > /etc/iptables.rules 2>/dev/null || true
                fi
                ok "iptables: port ${PORT} opened (tcp+udp)"
            else
                info "iptables has no restrictive rules, skipping"
            fi
        fi
    fi
}

# ── UDP performance tuning ───────────────────────────────────
tune_udp() {
    sysctl -w net.core.rmem_max=26214400 > /dev/null 2>&1
    sysctl -w net.core.rmem_default=26214400 > /dev/null 2>&1
    # Persist across reboots
    grep -q 'rmem_max' /etc/sysctl.conf 2>/dev/null || {
        echo "net.core.rmem_max=26214400" >> /etc/sysctl.conf
        echo "net.core.rmem_default=26214400" >> /etc/sysctl.conf
    }
    ok "UDP buffer tuning applied"
}

# ── Print summary ────────────────────────────────────────────
print_summary() {
    local ip
    ip=$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

    local action_msg="Deployed Successfully!"
    if [[ -n "$EXISTING_VERSION" && "$EXISTING_VERSION" != "$SNELL_VERSION" ]]; then
        action_msg="Upgraded ${EXISTING_VERSION} -> ${SNELL_VERSION}!"
    elif [[ "$NEED_DOWNLOAD" == false && "$NEED_CONFIG" == false ]]; then
        action_msg="Already Up-to-Date (verified)"
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Snell Server ${SNELL_VERSION} ${action_msg}${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Server IP:    ${CYAN}${ip}${NC}"
    echo -e "  Port:         ${CYAN}${PORT}${NC}"
    echo -e "  PSK:          ${CYAN}${PSK}${NC}"
    echo -e "  Version:      ${CYAN}5${NC}"
    echo ""
    echo -e "  Config:       ${CONF_PATH}"
    echo -e "  Service:      systemctl {start|stop|restart|status} snell"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Surge Proxy Line:"
    echo -e "  ${YELLOW}MySnell = snell, ${ip}, ${PORT}, psk=${PSK}, version=5${NC}"
    echo ""
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  REMINDER: Cloud Security Group / Firewall${NC}"
    echo -e "${YELLOW}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  If your server is on a cloud platform, make sure to"
    echo -e "  open port ${CYAN}${PORT}${NC} (TCP+UDP) in your security group:"
    echo ""
    echo -e "  ${CYAN}AWS${NC}:    EC2 -> Security Groups -> Inbound Rules -> Add ${PORT}/tcp+udp"
    echo -e "  ${CYAN}GCP${NC}:    VPC Network -> Firewall -> Create rule -> tcp/udp:${PORT}"
    echo -e "  ${CYAN}Azure${NC}:  NSG -> Inbound Security Rules -> Add ${PORT}/tcp+udp"
    echo -e "  ${CYAN}Alibaba${NC}: ECS -> Security Group -> Add ${PORT}/tcp+udp"
    echo -e "  ${CYAN}Tencent${NC}: CVM -> Security Group -> Add ${PORT}/tcp+udp"
    echo -e "  ${CYAN}Vultr${NC}:  Firewall -> Add rule -> ${PORT}/tcp+udp"
    echo -e "  ${CYAN}DigitalOcean${NC}: Networking -> Firewalls -> Add ${PORT}/tcp+udp"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   Snell Server Auto-Setup Script         ║${NC}"
    echo -e "${CYAN}║   Version: ${SNELL_VERSION}                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    check_os
    detect_arch
    check_existing
    install_deps
    install_snell
    generate_config
    create_service
    configure_firewall
    tune_udp
    print_summary
}

main "$@"

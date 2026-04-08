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

# ── Install dependencies ─────────────────────────────────────
install_deps() {
    info "Installing dependencies..."
    apt-get update -qq
    apt-get install -y -qq wget unzip openssl > /dev/null 2>&1
    ok "Dependencies installed"
}

# ── Download & install Snell server ──────────────────────────
install_snell() {
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

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Snell Server ${SNELL_VERSION} Deployed Successfully!${NC}"
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
    install_deps
    install_snell
    generate_config
    create_service
    tune_udp
    print_summary
}

main "$@"

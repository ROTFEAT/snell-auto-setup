# Snell Server Auto-Setup

One-command script to deploy [Snell](https://manual.nssurge.com/others/snell.html) proxy server (v5.0.1) on Ubuntu/Debian and derivatives.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/ROTFEAT/snell-auto-setup/master/install.sh | sudo bash
```

## Features

1. **System check** — verifies Ubuntu/Debian, detects architecture (amd64, i386, aarch64, armv7l)
2. **Smart install** — detects existing installation, supports upgrade and reinstall
3. **Random config** — generates random port (10000-65535) and PSK (32 chars)
4. **Firewall** — auto-opens port in ufw / firewalld / iptables
5. **Health checks** — verifies service running, port listening, firewall rules
6. **UDP tuning** — optimizes kernel buffer for better performance
7. **Cloud reminder** — prints security group instructions for major cloud providers

## Repeated Execution

The script is safe to run multiple times:

| Scenario | Behavior |
|----------|----------|
| First install | Download binary + generate random port/PSK + start service |
| Same version | Skip download, **preserve existing port & PSK**, verify health |
| Different version | Stop service, download new version, **preserve port & PSK**, restart |

Existing config (`/etc/snell-server.conf`) is never overwritten — your client-side settings stay valid.

## Output Example

```
════════════════════════════════════════════════════
  Snell Server v5.0.1 Deployed Successfully!
════════════════════════════════════════════════════

  Server IP:    203.0.113.1
  Port:         38472
  PSK:          AbCdEfGhIjKlMnOpQrStUvWx12345678
  Version:      5
  Health:       ALL CHECKS PASSED

  Surge Proxy Line:
  MySnell = snell, 203.0.113.1, 38472, psk=AbCdEfGhIjKlMnOpQrStUvWx12345678, version=5s

════════════════════════════════════════════════════
  REMINDER: Cloud Security Group / Firewall
════════════════════════════════════════════════════

  AWS:    EC2 -> Security Groups -> Inbound Rules -> Add 38472/tcp+udp
  GCP:    VPC Network -> Firewall -> Create rule -> tcp/udp:38472
  Azure:  NSG -> Inbound Security Rules -> Add 38472/tcp+udp
  Alibaba: ECS -> Security Group -> Add 38472/tcp+udp
  Tencent: CVM -> Security Group -> Add 38472/tcp+udp
  ...
```

## Management

```bash
sudo systemctl status snell      # Check status
sudo systemctl restart snell     # Restart
sudo systemctl stop snell        # Stop
sudo cat /etc/snell-server.conf  # View config
```

## Requirements

- Linux with systemd (Ubuntu, Debian, and derivatives like Mint, Pop!_OS, Armbian, Kali, etc.)
- Supported architectures: amd64, i386, aarch64, armv7l
- Root access

## License

MIT

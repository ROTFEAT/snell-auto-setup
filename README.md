# Snell Server Auto-Setup

One-command script to deploy [Snell](https://manual.nssurge.com/others/snell.html) proxy server on Ubuntu/Debian.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/yxwuxing/snell-auto-setup/main/install.sh | sudo bash
```

## What it does

1. **Checks OS** — verifies Ubuntu/Debian
2. **Detects architecture** — supports amd64, i386, aarch64, armv7l
3. **Downloads** the latest Snell server (v5.0.1)
4. **Generates** a random port (10000-65535) and PSK
5. **Creates** systemd service with auto-restart
6. **Tunes** UDP buffer for better performance
7. **Prints** connection details and Surge proxy line

## Output Example

```
════════════════════════════════════════════════════
  Snell Server v5.0.1 Deployed Successfully!
════════════════════════════════════════════════════

  Server IP:    203.0.113.1
  Port:         38472
  PSK:          AbCdEfGhIjKlMnOpQrStUvWx12345678
  Version:      5

  Surge Proxy Line:
  MySnell = snell, 203.0.113.1, 38472, psk=AbCdEfGhIjKlMnOpQrStUvWx12345678, version=5
```

## Management

```bash
sudo systemctl status snell    # Check status
sudo systemctl restart snell   # Restart
sudo systemctl stop snell      # Stop
sudo cat /etc/snell-server.conf  # View config
```

## Requirements

- Ubuntu or Debian
- Root access

## License

MIT

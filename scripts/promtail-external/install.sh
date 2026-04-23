#!/usr/bin/env bash
# Install Promtail as a systemd service on a non-cluster Ubuntu machine.
# Ships syslog/kern/auth and systemd journal to Loki at http://192.168.0.220
#
# Usage: sudo bash install.sh [HOSTNAME]
# Example: sudo bash install.sh mudshark
#
# Requires: curl, systemd, Ubuntu 22.04 or 24.04
set -euo pipefail

LOKI_IP="192.168.0.220"
PROMTAIL_VERSION="3.3.2"
ARCH="amd64"
HOSTNAME_LABEL="${1:-$(hostname)}"

echo "==> Installing Promtail $PROMTAIL_VERSION for $HOSTNAME_LABEL → Loki at $LOKI_IP"

# Create promtail user (no login shell, no home directory)
id promtail &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin promtail
usermod -aG adm promtail
usermod -aG systemd-journal promtail

# Download Promtail binary
DOWNLOAD_URL="https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-${ARCH}.zip"
curl -fsSL -o /tmp/promtail.zip "$DOWNLOAD_URL"
unzip -o /tmp/promtail.zip -d /tmp/
install -m 755 /tmp/promtail-linux-${ARCH} /usr/local/bin/promtail
rm -f /tmp/promtail.zip /tmp/promtail-linux-${ARCH}

# Create directories
mkdir -p /etc/promtail /var/lib/promtail
chown promtail:promtail /var/lib/promtail

# Install config (replace __HOSTNAME__ placeholder)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s/__HOSTNAME__/${HOSTNAME_LABEL}/g" "${SCRIPT_DIR}/promtail-external.yaml" > /etc/promtail/promtail.yaml
chown promtail:promtail /etc/promtail/promtail.yaml
chmod 640 /etc/promtail/promtail.yaml

# Install systemd unit
cp "${SCRIPT_DIR}/promtail.service" /etc/systemd/system/promtail.service

# Enable and start
systemctl daemon-reload
systemctl enable promtail
systemctl restart promtail

echo "==> Promtail installed and started. Check status:"
echo "    systemctl status promtail"
echo "    journalctl -u promtail -f"

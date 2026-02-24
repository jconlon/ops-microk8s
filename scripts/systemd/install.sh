#!/bin/bash
#
# install.sh - Install music sync systemd service and timer
#
# Usage: sudo ./install.sh
#

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo"
    echo "Usage: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

echo "Installing music sync systemd service..."

# Copy service files
echo "  Copying service files to $SYSTEMD_DIR..."
cp "$SCRIPT_DIR/music-sync.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/music-sync.timer" "$SYSTEMD_DIR/"

# Create log file with proper permissions
echo "  Creating log file..."
touch /var/log/music-sync.log
chown jconlon:jconlon /var/log/music-sync.log
chmod 644 /var/log/music-sync.log

# Reload systemd
echo "  Reloading systemd daemon..."
systemctl daemon-reload

# Enable timer
echo "  Enabling music-sync.timer..."
systemctl enable music-sync.timer

# Start timer
echo "  Starting music-sync.timer..."
systemctl start music-sync.timer

echo ""
echo "✅ Installation complete!"
echo ""
echo "The music sync service will run daily at 2:00 AM."
echo ""
echo "Useful commands:"
echo "  Check timer status:     systemctl status music-sync.timer"
echo "  List upcoming runs:     systemctl list-timers music-sync.timer"
echo "  Manual sync now:        sudo systemctl start music-sync.service"
echo "  View logs:              sudo journalctl -u music-sync.service"
echo "  View log file:          tail -f /var/log/music-sync.log"
echo ""

# Show next scheduled run
echo "Next scheduled run:"
systemctl list-timers music-sync.timer | grep music-sync || true

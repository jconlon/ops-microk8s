#!/bin/bash
#
# install-restic.sh - Install Restic systemd automation
#
# Usage: sudo ./install-restic.sh
#

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run with sudo"
    echo "Usage: sudo ./install-restic.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"

echo "Installing Restic systemd automation..."

# Copy service files
echo "  Copying service files to $SYSTEMD_DIR..."
cp "$SCRIPT_DIR/restic-backup.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/restic-backup.timer" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/restic-prune.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/restic-prune.timer" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/restic-verify.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/restic-verify.timer" "$SYSTEMD_DIR/"

# Create log files with proper permissions
echo "  Creating log files..."
touch /var/log/restic-backup.log
touch /var/log/restic-prune.log
touch /var/log/restic-verify.log
chown jconlon:jconlon /var/log/restic-backup.log
chown jconlon:jconlon /var/log/restic-prune.log
chown jconlon:jconlon /var/log/restic-verify.log
chmod 644 /var/log/restic-backup.log
chmod 644 /var/log/restic-prune.log
chmod 644 /var/log/restic-verify.log

# Reload systemd
echo "  Reloading systemd daemon..."
systemctl daemon-reload

# Enable timers
echo "  Enabling timers..."
systemctl enable restic-backup.timer
systemctl enable restic-prune.timer
systemctl enable restic-verify.timer

# Start timers
echo "  Starting timers..."
systemctl start restic-backup.timer
systemctl start restic-prune.timer
systemctl start restic-verify.timer

echo ""
echo "✅ Installation complete!"
echo ""
echo "Restic automation schedule:"
echo "  Backup:  Daily at 3:00 AM"
echo "  Prune:   Weekly (Sunday) at 4:00 AM"
echo "  Verify:  Monthly (1st) at 5:00 AM"
echo ""
echo "Useful commands:"
echo "  Check timers:           systemctl list-timers restic-*"
echo "  Manual backup now:      sudo systemctl start restic-backup.service"
echo "  Manual prune now:       sudo systemctl start restic-prune.service"
echo "  Manual verify now:      sudo systemctl start restic-verify.service"
echo "  View backup logs:       sudo journalctl -u restic-backup.service"
echo "  View log files:         tail -f /var/log/restic-*.log"
echo "  Check service status:   systemctl status restic-backup.timer"
echo ""

# Show next scheduled runs
echo "Next scheduled runs:"
systemctl list-timers restic-* | grep restic || true

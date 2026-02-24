#!/bin/bash
#
# install-pictures-sync.sh
# Install systemd service and timer for automated pictures sync
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing pictures sync systemd service and timer..."

# Copy service and timer files
sudo cp "$SCRIPT_DIR/pictures-sync.service" /etc/systemd/system/
sudo cp "$SCRIPT_DIR/pictures-sync.timer" /etc/systemd/system/

echo "Creating log file..."
sudo touch /var/log/pictures-sync.log
sudo chown jconlon:jconlon /var/log/pictures-sync.log

echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

echo "Enabling timer..."
sudo systemctl enable pictures-sync.timer

echo "Starting timer..."
sudo systemctl start pictures-sync.timer

echo ""
echo "Installation complete!"
echo ""
echo "Status:"
sudo systemctl status pictures-sync.timer --no-pager
echo ""
echo "Next scheduled run:"
systemctl list-timers pictures-sync.timer --no-pager
echo ""
echo "To manually trigger sync now:"
echo "  sudo systemctl start pictures-sync.service"
echo ""
echo "To view logs:"
echo "  sudo journalctl -u pictures-sync.service -f"
echo "  tail -f /var/log/pictures-sync.log"

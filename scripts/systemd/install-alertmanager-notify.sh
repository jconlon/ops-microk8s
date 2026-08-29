#!/bin/bash
#
# install-alertmanager-notify.sh
# Install a systemd --user service and timer that polls Alertmanager and
# sends desktop notifications via notify-send.
#
# Deliberately a --user unit, not a system unit (unlike music-sync/
# pictures-sync/restic in this same directory): notify-send needs the
# logged-in desktop session's D-Bus bus, which a system-level unit doesn't
# have without extra plumbing. --user units inherit it automatically.
# Run as your normal user — do NOT use sudo.
#

set -e

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run this with sudo — these are systemd --user units, installed for your own login session."
    exit 1
fi

if ! command -v notify-send >/dev/null 2>&1; then
    echo "ERROR: notify-send not found. Install it first: sudo apt install libnotify-bin"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"

echo "Installing alertmanager-notify systemd --user service and timer..."

mkdir -p "$USER_SYSTEMD_DIR"
cp "$SCRIPT_DIR/alertmanager-notify.service" "$USER_SYSTEMD_DIR/"
cp "$SCRIPT_DIR/alertmanager-notify.timer" "$USER_SYSTEMD_DIR/"

echo "Reloading systemd --user daemon..."
systemctl --user daemon-reload

echo "Enabling and starting the timer..."
systemctl --user enable --now alertmanager-notify.timer

echo ""
echo "Installation complete!"
echo ""
echo "Status:"
systemctl --user status alertmanager-notify.timer --no-pager
echo ""
echo "Next scheduled run:"
systemctl --user list-timers alertmanager-notify.timer --no-pager
echo ""
echo "To manually trigger a check now:"
echo "  systemctl --user start alertmanager-notify.service"
echo ""
echo "To view logs:"
echo "  journalctl --user -u alertmanager-notify.service -f"

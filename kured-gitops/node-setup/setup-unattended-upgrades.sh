#!/bin/bash
# Run on each cluster node to configure unattended-upgrades.
# Installs and configures automatic security patching.
# Reboots are intentionally disabled here — kured handles them.
#
# Usage: sudo bash setup-unattended-upgrades.sh
#
# Nodes: mullet, trout, tuna, whale, gold, squid, puffer, carp

set -euo pipefail

echo "Installing unattended-upgrades..."
apt-get install -y unattended-upgrades update-notifier-common

echo "Configuring auto-upgrades..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

echo "Configuring unattended-upgrades policy..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Do NOT auto-reboot — kured watches /var/run/reboot-required and handles
// rolling node drains and reboots safely across the cluster.
Unattended-Upgrade::Automatic-Reboot "false";

// Write reboot-required sentinel file so kured can detect when a reboot is needed
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

echo "Enabling and starting unattended-upgrades service..."
systemctl enable unattended-upgrades
systemctl restart unattended-upgrades

echo "Done. Verifying..."
systemctl status unattended-upgrades --no-pager

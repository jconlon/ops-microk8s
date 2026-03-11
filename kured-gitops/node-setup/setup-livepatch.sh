#!/bin/bash
# Run on Ubuntu Pro Free nodes to enable Canonical Livepatch.
# Livepatch applies kernel patches without rebooting for eligible CVEs.
#
# Ubuntu Pro Free covers 5 machines per personal account.
#
# Nodes with Livepatch (Ubuntu Pro Free):
#   mullet, trout, whale  — control plane (highest priority)
#   tuna                  — primary worker
#   gold                  — lead Ceph storage node
#
# Nodes WITHOUT Livepatch (kured handles reboots):
#   squid, puffer, carp   — remaining Ceph storage nodes
#
# Usage: sudo bash setup-livepatch.sh <ubuntu-pro-token>
#
# Get your token at: https://ubuntu.com/pro/dashboard

set -euo pipefail

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
    echo "Usage: sudo bash setup-livepatch.sh <ubuntu-pro-token>"
    echo "Get your token at: https://ubuntu.com/pro/dashboard"
    exit 1
fi

echo "Attaching Ubuntu Pro subscription..."
pro attach "$TOKEN"

echo "Enabling Livepatch..."
pro enable livepatch

echo "Verifying Livepatch status..."
canonical-livepatch status

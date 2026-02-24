#!/bin/bash
#
# restic-verify.sh
# Verify integrity of Restic repository
#

set -e

DOTFILES_DIR="/home/jconlon/dotfiles"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting Restic repository verification..."

# Change to dotfiles directory for devbox context
cd "$DOTFILES_DIR"

# Run repository check via teller
log "Checking repository integrity (reading 5% of data)..."
/usr/local/bin/devbox run --config /home/jconlon/dotfiles/devbox.json -- teller \
  --config /home/jconlon/dotfiles/restic/restic/.teller-restic-ceph.yml \
  run -- restic check --read-data-subset=5%

# List recent snapshots
log "Recent snapshots:"
/usr/local/bin/devbox run --config /home/jconlon/dotfiles/devbox.json -- teller \
  --config /home/jconlon/dotfiles/restic/restic/.teller-restic-ceph.yml \
  run -- restic snapshots --latest 5

log "Verification completed successfully"

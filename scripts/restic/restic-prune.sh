#!/bin/bash
#
# restic-prune.sh
# Enforce retention policy and prune old snapshots from Restic repository
#

set -e

DOTFILES_DIR="/home/jconlon/dotfiles"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting Restic prune operation..."

# Change to dotfiles directory for devbox context
cd "$DOTFILES_DIR"

# Run prune with retention policy via teller
log "Applying retention policy and pruning old snapshots..."
/usr/local/bin/devbox run --config /home/jconlon/dotfiles/devbox.json -- teller \
  --config /home/jconlon/dotfiles/restic/restic/.teller-restic-ceph.yml \
  run -- restic forget --prune \
    --keep-hourly 24 \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-yearly 2

# Show repository stats
log "Repository statistics after prune:"
/usr/local/bin/devbox run --config /home/jconlon/dotfiles/devbox.json -- teller \
  --config /home/jconlon/dotfiles/restic/restic/.teller-restic-ceph.yml \
  run -- restic stats --mode restore-size

log "Prune operation completed successfully"

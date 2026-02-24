#!/bin/bash
#
# sync-music-to-ceph.sh
# Sync music library from ~/Music to Ceph Object Storage (RGW)
#
# Usage: ./sync-music-to-ceph.sh
#

set -e

# Configuration
SOURCE="/home/jconlon/Music"
BUCKET="ceph-rgw/music-library"
LOG_FILE="/var/log/music-sync.log"
DEVBOX_DIR="/home/jconlon/git/ops-microk8s"

# Change to the ops-microk8s directory for devbox context
cd "$DEVBOX_DIR"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Start sync
log "Starting music library sync to Ceph..."
log "Source: $SOURCE"
log "Destination: $BUCKET"

# Check if source directory exists
if [ ! -d "$SOURCE" ]; then
    log "ERROR: Source directory $SOURCE does not exist"
    exit 1
fi

# Run sync with devbox, excluding hidden files
log "Running mc mirror sync..."
if devbox run -- mc mirror --exclude "*/.*" --remove "$SOURCE" "$BUCKET" 2>&1; then
    log "Sync completed successfully"

    # Get storage usage
    log "Storage usage:"
    devbox run -- mc du "$BUCKET" 2>&1 | while read line; do
        log "  $line"
    done

    log "Music library sync finished successfully"
    exit 0
else
    log "ERROR: Sync failed with exit code $?"
    exit 1
fi

#!/bin/bash
#
# sync-pictures-to-ceph.sh
# Sync pictures library from ~/Pictures/pictures to Ceph Object Storage (RGW)
#
# Usage: ./sync-pictures-to-ceph.sh
#

set -e

# Configuration
SOURCE="/home/jconlon/Pictures/pictures"
BUCKET="ceph-rgw/pictures"
LOG_FILE="/var/log/pictures-sync.log"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Start sync
log "Starting pictures library sync to Ceph..."
log "Source: $SOURCE"
log "Destination: $BUCKET"

# Check if source directory exists
if [ ! -d "$SOURCE" ]; then
    log "ERROR: Source directory $SOURCE does not exist"
    exit 1
fi

# Run sync, excluding hidden files
log "Running mc mirror sync..."
if mc mirror --exclude "*/.*" --remove "$SOURCE" "$BUCKET" 2>&1; then
    log "Sync completed successfully"

    # Get storage usage
    log "Storage usage:"
    mc du "$BUCKET" 2>&1 | while read line; do
        log "  $line"
    done

    log "Pictures library sync finished successfully"
    exit 0
else
    log "ERROR: Sync failed with exit code $?"
    exit 1
fi

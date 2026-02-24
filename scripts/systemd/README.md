# Ceph Object Storage Sync Services

Automated daily sync of media libraries to Ceph Object Storage (RGW).

## Available Services

1. **Music Sync** - Syncs `~/Music` to `ceph-rgw/music-library` at 2:00 AM daily
2. **Pictures Sync** - Syncs `~/Pictures/pictures` to `ceph-rgw/pictures` at 3:00 AM daily

---

## Pictures Sync Service

Automated daily sync of pictures library from `~/Pictures/pictures` to Ceph Object Storage.

### Quick Install

```bash
# Run the installation script
/home/jconlon/git/ops-microk8s/scripts/systemd/install-pictures-sync.sh
```

### Manual Installation

```bash
# Copy service and timer files to systemd directory
sudo cp /home/jconlon/git/ops-microk8s/scripts/systemd/pictures-sync.service /etc/systemd/system/
sudo cp /home/jconlon/git/ops-microk8s/scripts/systemd/pictures-sync.timer /etc/systemd/system/

# Create log file with proper permissions
sudo touch /var/log/pictures-sync.log
sudo chown jconlon:jconlon /var/log/pictures-sync.log

# Reload systemd to recognize new files
sudo systemctl daemon-reload

# Enable and start the timer
sudo systemctl enable pictures-sync.timer
sudo systemctl start pictures-sync.timer
```

### Management Commands

#### Check timer status
```bash
# See when the timer will run next
sudo systemctl status pictures-sync.timer
systemctl list-timers pictures-sync.timer
```

#### Check service status
```bash
# See last sync job status
sudo systemctl status pictures-sync.service
```

#### View logs
```bash
# View all sync logs
sudo journalctl -u pictures-sync.service

# Follow logs in real-time
sudo journalctl -u pictures-sync.service -f

# View log file directly
tail -f /var/log/pictures-sync.log
```

#### Manual sync
```bash
# Trigger sync immediately (without waiting for timer)
sudo systemctl start pictures-sync.service

# Watch logs while it runs
sudo journalctl -u pictures-sync.service -f
```

#### Disable/Stop
```bash
# Stop the timer (no more automatic syncs)
sudo systemctl stop pictures-sync.timer
sudo systemctl disable pictures-sync.timer

# Re-enable later
sudo systemctl enable pictures-sync.timer
sudo systemctl start pictures-sync.timer
```

### Schedule

- **Scheduled run**: Daily at 3:00 AM
- **Missed run**: If system was off at 3 AM, runs 10 minutes after next boot
- **Persistent**: Ensures sync happens even after system downtime

### Files

- **Service**: `/etc/systemd/system/pictures-sync.service` - Defines what to run
- **Timer**: `/etc/systemd/system/pictures-sync.timer` - Defines when to run
- **Script**: `/home/jconlon/git/ops-microk8s/scripts/sync-pictures-to-ceph.sh` - Actual sync script
- **Log**: `/var/log/pictures-sync.log` - Sync output and errors

### Uninstall

```bash
# Stop and disable
sudo systemctl stop pictures-sync.timer
sudo systemctl disable pictures-sync.timer

# Remove files
sudo rm /etc/systemd/system/pictures-sync.service
sudo rm /etc/systemd/system/pictures-sync.timer

# Reload systemd
sudo systemctl daemon-reload
```

---

## Music Sync Service

Automated daily sync of music library from `~/Music` to Ceph Object Storage.

### Installation

```bash
# Copy service and timer files to systemd directory
sudo cp /home/jconlon/git/ops-microk8s/scripts/systemd/music-sync.service /etc/systemd/system/
sudo cp /home/jconlon/git/ops-microk8s/scripts/systemd/music-sync.timer /etc/systemd/system/

# Create log file with proper permissions
sudo touch /var/log/music-sync.log
sudo chown jconlon:jconlon /var/log/music-sync.log

# Reload systemd to recognize new files
sudo systemctl daemon-reload

# Enable and start the timer
sudo systemctl enable music-sync.timer
sudo systemctl start music-sync.timer
```

## Management Commands

### Check timer status
```bash
# See when the timer will run next
sudo systemctl status music-sync.timer
systemctl list-timers music-sync.timer
```

### Check service status
```bash
# See last sync job status
sudo systemctl status music-sync.service
```

### View logs
```bash
# View all sync logs
sudo journalctl -u music-sync.service

# Follow logs in real-time
sudo journalctl -u music-sync.service -f

# View log file directly
tail -f /var/log/music-sync.log
```

### Manual sync
```bash
# Trigger sync immediately (without waiting for timer)
sudo systemctl start music-sync.service

# Watch logs while it runs
sudo journalctl -u music-sync.service -f
```

### Disable/Stop
```bash
# Stop the timer (no more automatic syncs)
sudo systemctl stop music-sync.timer
sudo systemctl disable music-sync.timer

# Re-enable later
sudo systemctl enable music-sync.timer
sudo systemctl start music-sync.timer
```

## Schedule

- **Scheduled run**: Daily at 2:00 AM
- **Missed run**: If system was off at 2 AM, runs 5 minutes after next boot
- **Persistent**: Ensures sync happens even after system downtime

## Files

- **Service**: `/etc/systemd/system/music-sync.service` - Defines what to run
- **Timer**: `/etc/systemd/system/music-sync.timer` - Defines when to run
- **Script**: `/home/jconlon/git/ops-microk8s/scripts/sync-music-to-ceph.sh` - Actual sync script
- **Log**: `/var/log/music-sync.log` - Sync output and errors

### Troubleshooting

#### Timer not running
```bash
# Check if timer is active
systemctl is-active music-sync.timer

# Check if timer is enabled
systemctl is-enabled music-sync.timer

# View timer details
systemctl show music-sync.timer
```

#### Service failing
```bash
# View recent failures
sudo journalctl -u music-sync.service --since today

# Test the script manually
/home/jconlon/git/ops-microk8s/scripts/sync-music-to-ceph.sh
```

#### Check next scheduled run
```bash
systemctl list-timers --all | grep music-sync
```

### Uninstall

```bash
# Stop and disable
sudo systemctl stop music-sync.timer
sudo systemctl disable music-sync.timer

# Remove files
sudo rm /etc/systemd/system/music-sync.service
sudo rm /etc/systemd/system/music-sync.timer

# Reload systemd
sudo systemctl daemon-reload
```

---

## General Troubleshooting

### View all sync timers
```bash
# See both music and pictures sync schedules
systemctl list-timers | grep -E "music-sync|pictures-sync"
```

### Check Ceph RGW connectivity
```bash
# Verify mc can connect to ceph-rgw
mc ls ceph-rgw/

# Check specific buckets
mc du ceph-rgw/music-library
mc du ceph-rgw/pictures
```

### View all sync service logs
```bash
# Music sync logs
sudo journalctl -u music-sync.service --since today

# Pictures sync logs
sudo journalctl -u pictures-sync.service --since today

# Both combined
sudo journalctl -u music-sync.service -u pictures-sync.service --since today
```

### Test scripts manually
```bash
# Test music sync
/home/jconlon/git/ops-microk8s/scripts/sync-music-to-ceph.sh

# Test pictures sync
/home/jconlon/git/ops-microk8s/scripts/sync-pictures-to-ceph.sh
```

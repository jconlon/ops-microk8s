# Restic Backup Automation with Systemd

Automated Restic backups to Ceph Object Storage using systemd timers.

## Overview

This automation wraps the existing `restic-backup-ceph` script from `/home/jconlon/dotfiles/devbox.json` with systemd timers for scheduled execution.

### Components

- **Backup**: Daily at 3:00 AM
  - Uses existing `restic-backup-ceph` script
  - Backs up `/home/jconlon` to Ceph RGW
  - Secrets injected via teller from Google Secret Manager
  - Excludes: Music, Downloads, caches, build artifacts (see `restic-excludes.txt`)

- **Prune**: Weekly (Sunday) at 4:00 AM
  - Enforces retention policy
  - Removes old snapshots
  - Reclaims storage space
  - Retention: 24 hourly, 7 daily, 4 weekly, 6 monthly, 2 yearly

- **Verify**: Monthly (1st) at 5:00 AM
  - Checks repository integrity
  - Reads 5% of data for validation
  - Lists recent snapshots

## Installation

```bash
cd /home/jconlon/git/ops-microk8s/scripts/restic/systemd
sudo ./install-restic.sh
```

This will:
- Copy service and timer files to `/etc/systemd/system/`
- Create log files in `/var/log/`
- Enable and start all timers
- Display next scheduled runs

## Management Commands

### Check Timer Status

```bash
# See all Restic timers
systemctl list-timers restic-*

# Check specific timer
systemctl status restic-backup.timer
systemctl status restic-prune.timer
systemctl status restic-verify.timer
```

### Manual Execution

```bash
# Run backup immediately
sudo systemctl start restic-backup.service

# Run prune immediately
sudo systemctl start restic-prune.service

# Run verification immediately
sudo systemctl start restic-verify.service
```

### View Logs

```bash
# Via systemd journal
sudo journalctl -u restic-backup.service
sudo journalctl -u restic-prune.service
sudo journalctl -u restic-verify.service

# Follow logs in real-time
sudo journalctl -u restic-backup.service -f

# Via log files
tail -f /var/log/restic-backup.log
tail -f /var/log/restic-prune.log
tail -f /var/log/restic-verify.log

# All restic logs
tail -f /var/log/restic-*.log
```

### Service Status

```bash
# Check last run status
systemctl status restic-backup.service
systemctl status restic-prune.service
systemctl status restic-verify.service

# Check if timers are active
systemctl is-active restic-backup.timer
systemctl is-active restic-prune.timer
systemctl is-active restic-verify.timer
```

## Schedule

| Operation | Schedule | Service | Timer |
|-----------|----------|---------|-------|
| **Backup** | Daily at 3:00 AM | restic-backup.service | restic-backup.timer |
| **Prune** | Sunday at 4:00 AM | restic-prune.service | restic-prune.timer |
| **Verify** | 1st of month at 5:00 AM | restic-verify.service | restic-verify.timer |

All timers have `Persistent=true`, meaning if the system was off during scheduled time, they will run shortly after boot.

## Retention Policy

Configured in `restic-prune.sh`:

```bash
--keep-hourly 24      # Last 24 hours
--keep-daily 7        # Last 7 days
--keep-weekly 4       # Last 4 weeks
--keep-monthly 6      # Last 6 months
--keep-yearly 2       # Last 2 years
```

This keeps:
- All hourly backups for the last day
- One backup per day for the last week
- One backup per week for the last month
- One backup per month for the last 6 months
- One backup per year for the last 2 years

Old snapshots are marked for deletion and data is reclaimed weekly during prune.

## File Structure

```
scripts/restic/
├── restic-prune.sh                  # Prune script
├── restic-verify.sh                 # Verification script
└── systemd/
    ├── restic-backup.service        # Backup service (wraps restic-backup-ceph)
    ├── restic-backup.timer          # Daily timer
    ├── restic-prune.service         # Prune service
    ├── restic-prune.timer           # Weekly timer
    ├── restic-verify.service        # Verify service
    ├── restic-verify.timer          # Monthly timer
    ├── install-restic.sh            # Installation script
    └── README-restic.md             # This file

/var/log/
├── restic-backup.log                # Backup logs
├── restic-prune.log                 # Prune logs
└── restic-verify.log                # Verification logs
```

## Configuration

All configuration is in `/home/jconlon/dotfiles`:

- **Backup script**: `devbox.json` → `restic-backup-ceph`
- **Teller config**: `restic/restic/.teller-restic-ceph.yml`
- **Exclude list**: `/home/jconlon/restic/restic-excludes.txt`
- **Secrets**: Google Secret Manager (via teller)

No local configuration files are created - everything uses existing dotfiles setup.

## Secrets Management

Secrets are managed via **teller** and **Google Secret Manager**:

- `RESTIC_REPOSITORY`: s3:http://192.168.0.204/restic-backups
- `RESTIC_PASSWORD`: Restic encryption password
- `AWS_ACCESS_KEY_ID`: Ceph RGW access key
- `AWS_SECRET_ACCESS_KEY`: Ceph RGW secret key

Secrets are injected at runtime - no credentials stored on disk.

## Troubleshooting

### Timer not running

```bash
# Check if timer is enabled and active
systemctl is-enabled restic-backup.timer
systemctl is-active restic-backup.timer

# Enable and start if needed
sudo systemctl enable restic-backup.timer
sudo systemctl start restic-backup.timer
```

### Service failing

```bash
# View recent failures
sudo journalctl -u restic-backup.service --since today

# Check service status
systemctl status restic-backup.service

# Test script manually
cd /home/jconlon/dotfiles
devbox run restic-backup-ceph
```

### Logs not appearing

```bash
# Check log file permissions
ls -la /var/log/restic-*.log

# Check service output
sudo journalctl -u restic-backup.service -n 100
```

### Prune taking too long

Prune can be slow on large repositories. This is normal. Monitor progress:

```bash
# Watch prune logs
tail -f /var/log/restic-prune.log

# Check if prune service is running
systemctl status restic-prune.service
```

### Google Secret Manager access issues

```bash
# Verify gcloud authentication
gcloud auth list

# Test teller access
cd /home/jconlon/dotfiles
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml show
```

## Disable/Stop Automation

```bash
# Stop timers (no more automatic backups)
sudo systemctl stop restic-backup.timer
sudo systemctl stop restic-prune.timer
sudo systemctl stop restic-verify.timer

# Disable timers (won't start on boot)
sudo systemctl disable restic-backup.timer
sudo systemctl disable restic-prune.timer
sudo systemctl disable restic-verify.timer
```

## Re-enable Automation

```bash
# Enable and start timers
sudo systemctl enable restic-backup.timer restic-prune.timer restic-verify.timer
sudo systemctl start restic-backup.timer restic-prune.timer restic-verify.timer
```

## Uninstall

```bash
# Stop and disable all timers
sudo systemctl stop restic-backup.timer restic-prune.timer restic-verify.timer
sudo systemctl disable restic-backup.timer restic-prune.timer restic-verify.timer

# Remove systemd files
sudo rm /etc/systemd/system/restic-*.service
sudo rm /etc/systemd/system/restic-*.timer

# Reload systemd
sudo systemctl daemon-reload

# Optional: Remove log files
sudo rm /var/log/restic-*.log
```

## Monitoring

### Check Last Backup

```bash
# View last backup in logs
tail /var/log/restic-backup.log

# Or via journalctl
sudo journalctl -u restic-backup.service -n 50

# Or check restic directly
cd /home/jconlon/dotfiles
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml run -- restic snapshots --latest 1
```

### Check Repository Size

```bash
cd /home/jconlon/dotfiles
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml run -- restic stats --mode restore-size
```

### List Recent Snapshots

```bash
cd /home/jconlon/dotfiles
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml run -- restic snapshots --latest 10
```

## Testing

Before relying on automation, test each component:

```bash
# 1. Test backup
sudo systemctl start restic-backup.service
sudo journalctl -u restic-backup.service -f

# 2. Test prune (be careful - this will delete old snapshots!)
sudo systemctl start restic-prune.service
sudo journalctl -u restic-prune.service -f

# 3. Test verify
sudo systemctl start restic-verify.service
sudo journalctl -u restic-verify.service -f

# 4. Check timers are scheduled
systemctl list-timers restic-*
```

## Performance

Expected durations (will vary based on data):

- **Backup**: 10-15 minutes for incremental (990K files, ~105 GiB)
- **Prune**: 5-30 minutes depending on repository size
- **Verify**: 10-60 minutes depending on data size (5% sampling)

## Related Documentation

- Original setup: `/home/jconlon/dotfiles/restic/restic/README.md`
- Teller config: `/home/jconlon/dotfiles/restic/restic/.teller-restic-ceph.yml`
- Exclude list: `/home/jconlon/restic/restic-excludes.txt`
- Issue #18: Restic automation tracking
- Issue #14: Restic migration to Ceph RGW

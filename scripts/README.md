# Scripts

Operational scripts for the MicroK8s cluster. NuShell scripts are invoked via the `ops` wrapper using `devbox run`. Bash scripts are called directly or by systemd services.

## Structure

```
scripts/
├── argocd.nu                    # ArgoCD management commands (nushell)
├── freshrss.nu                  # FreshRSS database access (nushell)
├── sync-music-to-ceph.sh        # Sync ~/Music to Ceph RGW
├── sync-pictures-to-ceph.sh     # Sync ~/Pictures to Ceph RGW
├── systemd/                     # Systemd service/timer units for sync jobs
│   ├── README.md
│   ├── install.sh               # Install music sync service
│   ├── install-pictures-sync.sh # Install pictures sync service
│   ├── music-sync.service
│   ├── music-sync.timer         # Daily at 2:00 AM
│   ├── pictures-sync.service
│   └── pictures-sync.timer      # Daily at 3:00 AM
└── restic/                      # Restic backup scripts and systemd units
    ├── restic-prune.sh          # Enforce retention policy
    ├── restic-verify.sh         # Verify repository integrity
    └── systemd/
        ├── README-restic.md
        ├── install-restic.sh
        ├── restic-backup.service
        ├── restic-backup.timer   # Daily at 3:00 AM
        ├── restic-prune.service
        ├── restic-prune.timer    # Weekly (Sunday) at 4:00 AM
        ├── restic-verify.service
        └── restic-verify.timer   # Monthly (1st) at 5:00 AM
```

---

## NuShell Scripts

Sourced by the `ops` wrapper script. Run from the `ops-microk8s` directory.

### argocd.nu

ArgoCD server management commands.

| Command | Description |
|---|---|
| `ops argocd login` | Authenticate to ArgoCD (fetches password from cluster secret automatically) |
| `ops argocd logout` | Log out from ArgoCD |
| `ops argocd add-repo` | Add a GitHub repository to ArgoCD |
| `ops argocd list-repo` | List configured repositories |
| `ops argocd list-app` | List configured applications |

```bash
devbox run -- argocd-login

# Or from within devbox shell
ops argocd login
ops argocd login --server argocd.verticon.com --username admin
```

### freshrss.nu

FreshRSS database commands. Each command starts a `kubectl port-forward` as a background job, fetches credentials from the `freshrss-role-password` Kubernetes secret, and cleans up on exit.

| Command | Description |
|---|---|
| `ops freshrss psql` | Open an interactive `psql` session against the FreshRSS database |
| `ops freshrss publish-links` | Query entries tagged `publish` and print a markdown link list |

#### freshrss psql

```bash
devbox run -- freshrss-psql

# Or from within devbox shell
ops freshrss psql

# Custom local port (default: 5433)
ops freshrss psql --port 5434
```

#### freshrss publish-links

Queries the FreshRSS database for all entries tagged `publish` and outputs a markdown list of links with their tags.

```bash
# From ops-microk8s directory
devbox run -- freshrss-publish-links

# From any directory
devbox run --config /home/jconlon/git/ops-microk8s -- freshrss-publish-links

# Or from within devbox shell
ops freshrss publish-links
```

Example output:

```markdown
- [Article Title](https://example.com/article) — publish, review
```

**Prerequisites:** `kubectl` context must be pointing at the MicroK8s cluster.

---

## Bash Scripts

### sync-music-to-ceph.sh

Syncs `~/Music` to the `ceph-rgw/music-library` Ceph RGW bucket using `mc mirror`. Excludes hidden files. Logs to `/var/log/music-sync.log`.

```bash
./scripts/sync-music-to-ceph.sh
```

Typically run via the `music-sync` systemd timer (daily at 2:00 AM). See [systemd/README.md](systemd/README.md) for installation and management.

### sync-pictures-to-ceph.sh

Syncs `~/Pictures/pictures` to the `ceph-rgw/pictures` Ceph RGW bucket using `mc mirror`. Excludes hidden files. Logs to `/var/log/pictures-sync.log`.

```bash
./scripts/sync-pictures-to-ceph.sh
```

Typically run via the `pictures-sync` systemd timer (daily at 3:00 AM). See [systemd/README.md](systemd/README.md) for installation and management.

---

## Restic Backup Scripts

Restic backs up `/home/jconlon` to Ceph RGW (`s3:http://192.168.0.204/restic-backups`). Credentials are injected via teller from the dotfiles `.teller-restic-ceph.yml` config.

### restic/restic-prune.sh

Applies the retention policy and removes old snapshots:
- 24 hourly, 7 daily, 4 weekly, 6 monthly, 2 yearly

Typically run via the `restic-prune` systemd timer (weekly, Sunday at 4:00 AM).

### restic/restic-verify.sh

Verifies repository integrity by reading 5% of stored data and lists the 5 most recent snapshots.

Typically run via the `restic-verify` systemd timer (monthly, 1st at 5:00 AM).

See [restic/systemd/README-restic.md](restic/systemd/README-restic.md) for full installation and troubleshooting.

---

## Teller Configurations

Cluster teller configs live in `../teller/` (the `teller/` directory at the repo root). They pull secrets from Google Secret Manager and create Kubernetes secrets out-of-band (not managed by ArgoCD).

Run all teller commands from the `ops-microk8s` root directory within a devbox shell.

| Config | Purpose |
|---|---|
| `teller/.teller-freshrss.yml` | FreshRSS K8s secrets (`freshrss-db-credentials`, `freshrss-role-password`) |
| `teller/.teller-postgresql.yml` | PostgreSQL backup S3 credentials (`ceph-s3-credentials`) |

> **Note:** Machine-local teller configs (restic, gitlab) remain in `~/dotfiles`. Only cluster K8s secret configs belong here.

### Example: Recreate FreshRSS secrets

```bash
# Role password (postgresql-system namespace)
teller run --config teller/.teller-freshrss.yml -- bash -c 'kubectl create secret generic freshrss-role-password \
  --namespace postgresql-system \
  --from-literal=username=freshrss \
  --from-literal=password="$FRESHRSS_ROLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'

# DB credentials (freshrss namespace)
teller run --config teller/.teller-freshrss.yml -- bash -c 'kubectl create secret generic freshrss-db-credentials \
  --namespace freshrss \
  --from-literal=password="$FRESHRSS_DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'
```

### Example: Create PostgreSQL backup S3 credentials

```bash
teller run --config teller/.teller-postgresql.yml -- bash -c 'kubectl create secret generic ceph-s3-credentials \
  --namespace postgresql-system \
  --from-literal=ACCESS_KEY_ID="$ACCESS_KEY_ID" \
  --from-literal=ACCESS_SECRET_KEY="$ACCESS_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -'
```

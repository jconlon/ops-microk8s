# Scripts

Operational scripts for the MicroK8s cluster. NuShell scripts are invoked via the `ops` wrapper using `devbox run`. Bash scripts are called directly or by systemd services.

## Structure

```
scripts/
├── argocd.nu                    # ArgoCD management commands (nushell)
├── cluster.nu                   # Cluster health/status commands (nushell)
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

> **Note**: Claude Code sessions always run inside the devbox shell. Use direct commands — `devbox run --` prefixes are not needed.
>
> To run a script from **another directory**, use:
> ```bash
> devbox run --config /home/jconlon/git/ops-microk8s -- <script-name>
> # e.g.
> devbox run --config /home/jconlon/git/ops-microk8s -- freshrss-update-technical
> ```

Sourced by the `ops` wrapper script. Run from the `ops-microk8s` directory.

### cluster.nu

Cluster health and status commands. Queries Prometheus — no SSH required.

| Command | Description |
|---|---|
| `ops cluster node-uptime` | Show uptime for all 8 nodes via Prometheus |
| `ops cluster node-status` | Show uptime + kured reboot-required status for all nodes |

```bash
ops cluster node-uptime
ops cluster node-status
```

---

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
ops argocd login
ops argocd login --server argocd.verticon.com --username admin
```

### freshrss.nu

FreshRSS database commands. Each command connects directly to `postgresql.verticon.com:5432` (the readonly replica exposed via MetalLB), fetches credentials from the `freshrss-role-password` Kubernetes secret.

All query commands use the `v_freshrss_entries` view (see [`scripts/sql/v_freshrss_entries.sql`](sql/v_freshrss_entries.sql)), which joins all FreshRSS tables and exposes every entry column at its raw, untrimmed value. To recreate the view (requires primary — port-forward or run inside the cluster):

```bash
password=$(kubectl get secret freshrss-role-password -n postgresql-system -o jsonpath="{.data.password}" | base64 -d)
kubectl port-forward -n postgresql-system svc/production-postgresql-rw 5434:5432 &
PGPASSWORD="$password" psql -h localhost -p 5434 -U freshrss -d freshrss -f scripts/sql/v_freshrss_entries.sql
```

| Command | Description |
|---|---|
| `ops freshrss psql` | Open an interactive `psql` session against the FreshRSS database |
| `ops freshrss publish-links` | Query entries tagged `publish` and print a markdown link list |
| `ops freshrss update-news` | Query entries tagged `publish` and overwrite the `### Latest` section in `news/docs/index.md` |
| `ops freshrss update-technical` | Query entries tagged `technical` and overwrite the `### Technical` section in `news/docs/index.md` |
| `ops freshrss update-feed` | Generate RSS 2.0 feed from `publish`-tagged entries and write to `news/docs/feed.xml` |

#### freshrss psql

```bash
ops freshrss psql

# Override host (default: postgresql.verticon.com)
ops freshrss psql --host 192.168.0.211
```

#### freshrss publish-links

Queries the FreshRSS database for all entries tagged `publish` and outputs a markdown list of links with their tags.

```bash
ops freshrss publish-links
```

Example output:

```markdown
- [Article Title](https://example.com/article) — publish, review
```

**Prerequisites:** `kubectl` context must be pointing at the MicroK8s cluster.

#### freshrss update-news

Runs the same publish-links query and overwrites the `### Latest` section in `/home/jconlon/git/news/docs/index.md` with fresh output. Aborts safely if no links are returned.

```bash
ops freshrss update-news
```

**Prerequisites:** `kubectl` context must be pointing at the MicroK8s cluster. `/home/jconlon/git/news/docs/index.md` must exist and contain a `### Latest` heading.

#### freshrss update-technical

Queries FreshRSS for entries tagged `technical` and overwrites the `### Technical` section in `/home/jconlon/git/news/docs/index.md` with fresh output. Aborts safely if no links are returned.

```bash
ops freshrss update-technical
```

**Prerequisites:** `kubectl` context must be pointing at the MicroK8s cluster. `/home/jconlon/git/news/docs/index.md` must exist and contain a `### Technical` heading.

#### freshrss update-feed

Generates an RSS 2.0 feed from FreshRSS entries tagged `publish` and writes it to `/home/jconlon/git/news/docs/feed.xml`. The feed is deployed automatically as part of `just publish-news` and `just publish-news-tech` in the news repo, and will be served at `https://verticon.com/news/feed.xml`.

The feed includes the 50 most recent published entries with title, link, publication date, source feed name, and a description snippet. Each HTML page on the news site includes a `<link rel="alternate">` autodiscovery tag pointing to the feed.

```bash
ops freshrss update-feed
```

**Prerequisites:** `kubectl` context must be pointing at the MicroK8s cluster. `/home/jconlon/git/news/docs/` must exist.

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
| `teller/.teller-hasura.yml` | Hasura K8s secrets (`hasura-role-password`, `hasura-credentials`) |

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

### Example: Create Harbor secrets

> **Prerequisites:** Add `harbor-role`, `harbor-admin`, and `harbor-secret-key` (16 chars) to Google Secret Manager before running.

```bash
# Role password (postgresql-system namespace — used by CloudNativePG managed role)
teller run --config teller/.teller-harbor.yml -- bash -c 'kubectl create secret generic harbor-role-password \
  --namespace postgresql-system \
  --from-literal=username=harbor \
  --from-literal=password="$HARBOR_ROLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'

# DB credentials (harbor namespace — Harbor connects to CloudNativePG)
teller run --config teller/.teller-harbor.yml -- bash -c 'kubectl create secret generic harbor-db-credentials \
  --namespace harbor \
  --from-literal=password="$HARBOR_ROLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'

# Harbor credentials (harbor namespace — admin password + encryption key)
teller run --config teller/.teller-harbor.yml -- bash -c 'kubectl create secret generic harbor-credentials \
  --namespace harbor \
  --from-literal=HARBOR_ADMIN_PASSWORD="$HARBOR_ADMIN_PASSWORD" \
  --from-literal=secretKey="$HARBOR_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -'

# S3 credentials (harbor namespace — copy from Ceph user secret created by Rook)
ACCESS_KEY=$(kubectl get secret harbor-registry-user -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret harbor-registry-user -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create secret generic harbor-s3-credentials \
  --namespace harbor \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$ACCESS_KEY" \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### Example: Create Hasura secrets

> **Prerequisites:** Add `hasura-role` and `hasura-admin-secret` to Google Secret Manager before running.

```bash
# Role password (postgresql-system namespace — used by CloudNativePG managed role)
teller run --config teller/.teller-hasura.yml -- bash -c 'kubectl create secret generic hasura-role-password \
  --namespace postgresql-system \
  --from-literal=username=hasura \
  --from-literal=password="$HASURA_ROLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'

# App credentials (hasura namespace — metadata DB URL + admin secret)
teller run --config teller/.teller-hasura.yml -- bash -c 'kubectl create secret generic hasura-credentials \
  --namespace hasura \
  --from-literal=HASURA_GRAPHQL_METADATA_DATABASE_URL="postgres://hasura:$HASURA_ROLE_PASSWORD@production-postgresql-rw.postgresql-system.svc.cluster.local:5432/hasura" \
  --from-literal=HASURA_GRAPHQL_ADMIN_SECRET="$HASURA_GRAPHQL_ADMIN_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -'

# App credentials (cosmo namespace — Cosmo Router forwards admin secret to Hasura subgraph)
teller run --config teller/.teller-hasura.yml -- bash -c 'kubectl create secret generic hasura-credentials \
  --namespace cosmo \
  --from-literal=HASURA_GRAPHQL_METADATA_DATABASE_URL="postgres://hasura:$HASURA_ROLE_PASSWORD@production-postgresql-rw.postgresql-system.svc.cluster.local:5432/hasura" \
  --from-literal=HASURA_GRAPHQL_ADMIN_SECRET="$HASURA_GRAPHQL_ADMIN_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -'
```

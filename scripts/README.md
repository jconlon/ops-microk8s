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

### loki.nu

Loki log analysis commands via logcli. All commands query `http://192.168.0.220` (pre-set in devbox). Useful for investigating node issues, spurious shutdowns, and iDRAC hardware events.

| Command | Description |
|---|---|
| `ops loki node-events <node>` | Query syslog for a node (`--since 24h`, `--limit 100`, `--filter ""`) |
| `ops loki shutdown-events <node>` | Power/shutdown/reboot events + boot markers (`--since 7d`) |
| `ops loki idrac <node>` | iDRAC hardware events from a Dell R320 node (`--since 7d`) |
| `ops loki reboot-history` | Boot times + shutdown event count for all nodes (`--since 7d`) |
| `ops loki tail <node>` | Live tail syslog for a node (`--filter ""`) |

```bash
# Investigate puffer shutdowns over the last 7 days
ops loki shutdown-events puffer --since 7d

# Show all node boot times and how many times each shut down
ops loki reboot-history --since 30d

# Check iDRAC events for all Dell nodes
ops loki idrac puffer --since 30d
ops loki idrac carp --since 7d

# Search for a specific term in puffer syslog
ops loki node-events puffer --filter "ACPI" --since 24h

# Live tail
ops loki tail puffer
ops loki tail puffer --filter "iDRAC"
```

Also available as `just` recipes:
```bash
just loki-shutdown-events puffer 7d
just loki-reboot-history 30d
just loki-idrac puffer 7d
just loki-node-events puffer 24h
just loki-tail puffer
```

---

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
ops freshrss psql --host postgresql.verticon.com
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
| `teller/.teller-argo-workflows.yml` | Argo Workflows Harbor robot account credentials |
| `teller/.teller-hasura.yml` | Hasura K8s secrets (`hasura-role-password`, `hasura-credentials`) |
| `teller/.teller-cert-manager.yml` | Cloudflare API token for cert-manager's DNS-01 `ClusterIssuer` (`cloudflare-api-token-secret`) |
| `teller/.teller-kagent.yml` | KAgent K8s secrets (`kagent-role-password`, `kagent-db-credentials`) |

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

### Loki S3 credentials bootstrap

After ArgoCD wave 1 syncs the CephObjectStoreUser, get the Rook-generated secret name and copy credentials to the `loki` namespace. This must be done before wave 2 (Loki Helm chart) deploys:

```bash
# Get the Rook-generated secret name
SECRET_NAME=$(kubectl get cephobjectstoreuser loki-logs-user -n rook-ceph \
  -o jsonpath='{.status.info.secretName}')

# Copy S3 credentials to loki namespace
ACCESS_KEY=$(kubectl get secret $SECRET_NAME -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret $SECRET_NAME -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create namespace loki --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic loki-s3-credentials \
  --namespace loki \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### External Promtail install (mudshark/oyster/minnow)

For non-cluster Ubuntu machines, run Promtail as a systemd service to ship syslog and journal to Loki:

```bash
# On each external Ubuntu machine:
# Copy scripts/promtail-external/ to the machine, then:
sudo bash scripts/promtail-external/install.sh <hostname>
# e.g.:  sudo bash install.sh mudshark
```

The install script:
1. Creates a `promtail` system user
2. Downloads the Promtail binary from GitHub releases
3. Installs config to `/etc/promtail/promtail.yaml` (with hostname substituted)
4. Installs and starts the `promtail.service` systemd unit

Verify with: `systemctl status promtail` and `journalctl -u promtail -f`

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

---

### Example: Create kagent secrets (issue #111)

> **Prerequisites:** Add `kagent-role` to Google Secret Manager before running:
> ```bash
> gcloud secrets create kagent-role --replication-policy=automatic
> echo -n "<password>" | gcloud secrets versions add kagent-role --data-file=-
> ```

```bash
# Role password (postgresql-system namespace — used by CloudNativePG managed role)
teller run --config teller/.teller-kagent.yml -- bash -c 'kubectl create secret generic kagent-role-password \
  --namespace postgresql-system \
  --from-literal=username=kagent \
  --from-literal=password="$KAGENT_ROLE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -'

# DB connection secret (kagent namespace — full URL, mounted via urlFile in kagent-values.yaml)
teller run --config teller/.teller-kagent.yml -- bash -c 'kubectl create secret generic kagent-db-credentials \
  --namespace kagent \
  --from-literal=url="postgres://kagent:$KAGENT_ROLE_PASSWORD@production-postgresql-rw.postgresql-system.svc.cluster.local:5432/kagent" \
  --dry-run=client -o yaml | kubectl apply -f -'
```

One-time ArgoCD OCI repo registration and initial app bootstrap (not GitOps-managed, same class as the kgateway/cr.kgateway.dev registration):

```bash
argocd repo add ghcr.io/kagent-dev/kagent/helm --type helm --enable-oci
kubectl apply -f argoCD-apps/kagent-apps.yaml
```

#### kagent-grafana-mcp Grafana service account token

Required for kagent's observability-agent to query Grafana/Prometheus via MCP — without it, `kagent-grafana-mcp` returns 403 Forbidden and the agent's toolset fails to load. Not teller/GSM-managed — generated directly via Grafana's API and stored as a one-off Secret (it's a token scoped only to this integration, not a shared credential):

```bash
GRAFANA_ADMIN_PW=$(kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d)

SA_ID=$(curl -s -u "admin:$GRAFANA_ADMIN_PW" -X POST http://192.168.0.201/api/serviceaccounts \
  -H "Content-Type: application/json" -d '{"name":"kagent-mcp","role":"Viewer"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

TOKEN=$(curl -s -u "admin:$GRAFANA_ADMIN_PW" -X POST "http://192.168.0.201/api/serviceaccounts/$SA_ID/tokens" \
  -H "Content-Type: application/json" -d '{"name":"kagent-mcp-token"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['key'])")

kubectl create secret generic kagent-grafana-token -n kagent \
  --from-literal=GRAFANA_SERVICE_ACCOUNT_TOKEN="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

unset GRAFANA_ADMIN_PW TOKEN
```

After creating the secret, restart the pod so it picks up the new toolset: `kubectl delete pod -n kagent -l app.kubernetes.io/name=grafana-mcp`.

---

### cert-manager Cloudflare DNS-01 token bootstrap (issue #109)

> **Prerequisites:** Create a Cloudflare API token scoped to `Zone:DNS:Edit` on the `verticon.com` zone only (separate from Caddy's own token — see issue #109 for the dashboard steps), and add it to Google Secret Manager as `cert-manager-dns01-verticon` before running.
>
> **Why this exists:** `*.verticon.com` DNS records resolve publicly to private LAN IPs, so cert-manager's `ClusterIssuer` cannot use HTTP-01 (Let's Encrypt can never reach the cluster) — it needs the same DNS-01 mechanism Caddy already uses. See `docs/plans/2026-07-05-migrate-to-kgateway.md`'s Architectural Decisions for the full explanation.

```bash
teller run --config teller/.teller-cert-manager.yml -- bash -c '
  kubectl create secret generic cloudflare-api-token-secret \
    -n cert-manager \
    --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
'
```

Once the secret exists, `cert-manager-gitops/resources/cluster-issuer.yaml`'s `dns01.cloudflare.apiTokenSecretRef` solver can resolve it, and any pending `Certificate` (e.g. `pgadmin-tls`) should issue within a minute or two.

---

### Harbor bootstrap — create registry S3 bucket

After Harbor is deployed and the `harbor-s3-credentials` secret exists in the `harbor` namespace, create the registry bucket using `mc` via `s3.verticon.com` (issue #65):

```bash
ACCESS_KEY=$(kubectl get secret harbor-s3-credentials -n harbor \
  -o jsonpath='{.data.REGISTRY_STORAGE_S3_ACCESSKEY}' | base64 -d)
SECRET_KEY=$(kubectl get secret harbor-s3-credentials -n harbor \
  -o jsonpath='{.data.REGISTRY_STORAGE_S3_SECRETKEY}' | base64 -d)

mc alias set ceph-harbor https://s3.verticon.com "$ACCESS_KEY" "$SECRET_KEY"
mc mb ceph-harbor/harbor-registry
```

> **Note**: This bucket must be created before any image pushes to `registry.verticon.com`.
> Without it, pushes fail silently with an S3 error (issue #57).

Verify the registry is working:

```bash
docker login registry.verticon.com   # admin / Harbor admin password
docker pull alpine:latest
docker tag alpine:latest registry.verticon.com/library/alpine:test
docker push registry.verticon.com/library/alpine:test
mc ls -r ceph-harbor/harbor-registry   # confirm layers stored in Ceph
```

---

### Argo Workflows bootstrap

After the `argo-workflows-storage` ArgoCD app syncs (CephObjectStoreUser becomes Ready), run once to create S3 credentials and the artifact bucket:

```bash
# Copy Rook-generated S3 credentials to argo-workflows namespace
SECRET_NAME=$(kubectl get cephobjectstoreuser argo-artifact-user -n rook-ceph \
  -o jsonpath='{.status.info.secretName}')
ACCESS_KEY=$(kubectl get secret "$SECRET_NAME" -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret "$SECRET_NAME" -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create namespace argo-workflows --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic argo-workflows-s3-credentials \
  --namespace argo-workflows \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create the artifact bucket via mc using s3.verticon.com (issue #65)
# MC_HOST_ceph is set in the devbox init_hook — credentials from the secret above
mc alias set ceph https://s3.verticon.com "$ACCESS_KEY" "$SECRET_KEY"
mc mb ceph/argo-artifacts
```

> **Note**: `radosgw-admin bucket create` does not exist — bucket creation must be done
> via an S3 client (`mc`, `aws`, etc.) against the RGW endpoint. The `argo-artifacts`
> bucket must be created before any workflows are submitted; without it every workflow
> will fail with `exit code 64: The specified bucket does not exist` (issue #58).

After deploying, expose it via kgateway (see README.md's "Adding a New DNS Name for a Service" — as of issue #108, no longer a Caddy proxy entry): add a `Certificate` + Gateway HTTPS listener + `HTTPRoute` for `workflows.verticon.com`, and a Cloudflare A record pointing at the shared kgateway IP `192.168.0.224`.

#### Harbor robot account (for image push/pull in workflows)

1. Create robot account in Harbor: `https://registry.verticon.com → Administration → Robot Accounts → New Robot Account`
   - Name: `argo-workflows`
   - Permissions: push/pull on relevant projects
2. Add the secret to Google Secret Manager as `harbor-argo-robot`
3. Run:

```bash
teller run --config teller/.teller-argo-workflows.yml -- bash -c '
  kubectl create secret docker-registry harbor-credentials \
    --namespace argo-workflows \
    --docker-server=registry.verticon.com \
    --docker-username="robot\$argo-workflows" \
    --docker-password="$HARBOR_ARGO_ROBOT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
'
```

---

### Argo Events — events.verticon.com

The Argo Events WebhookEventSource is exposed at https://events.verticon.com/push, fronted by kgateway (issue #108) rather than a dedicated Caddy proxy entry — see README.md's "Adding a New DNS Name for a Service" for the `Certificate`/`Gateway` listener/`HTTPRoute` pattern (`kgateway-gitops/resources/httproutes/events-httproute.yaml`, backend `git-push-eventsource-lb` in `argo-events`, port 12000).

**DNS**: Cloudflare A record: events.verticon.com → 192.168.0.224 (shared kgateway IP, DNS only, not proxied)

**Test**: `curl -X POST https://events.verticon.com/push -d '{"repo":"test","commit":"abc"}' -H 'Content-Type: application/json'`

**Git hook**: See `scripts/hooks/README.md` for instructions on installing the `post-push.tmpl` hook in any application repository to fire CI builds on `git push`.

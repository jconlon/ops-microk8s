# ops-microk8s

Infrastructure configuration for a MicroK8s cluster with 8 nodes: mullet, trout, tuna, whale, gold, squid, puffer, and carp. The cluster uses Rook/Ceph for distributed replicated storage. Monitoring is provided by Prometheus/Grafana.

## Cluster Overview

```bash
☸ microk8s (monitoring) in ops-microk8s [✘!?] took 8m0s
✗ k get no
NAME     STATUS   ROLES    AGE     VERSION
mullet   Ready    <none>   30d     v1.32.3
shamu    Ready    <none>   22d     v1.32.3
trout    Ready    <none>   22d     v1.32.3
tuna     Ready    <none>   4d20h   v1.32.3
whale    Ready    <none>   22d     v1.32.3

➜ microk8s status
microk8s is running
high-availability: yes
  datastore master nodes: 192.168.0.101:19001 192.168.0.107:19001 192.168.0.102:19001
  datastore standby nodes: none
addons:
  enabled:
    dns                  # (core) CoreDNS
    ha-cluster           # (core) Configure high availability on the current node
    helm                 # (core) Helm - the package manager for Kubernetes
    helm3                # (core) Helm 3 - the package manager for Kubernetes
    metallb              # (core) Loadbalancer for your Kubernetes cluster

➜ kubectl get nodes -l node.kubernetes.io/microk8s-controlplane=microk8s-controlplane
NAME     STATUS   ROLES    AGE   VERSION
mullet   Ready    <none>   30d   v1.32.3
trout    Ready    <none>   22d   v1.32.3
whale    Ready    <none>   22d   v1.32.3
```

## Architecture

### Cluster Configuration

- **Platform**: MicroK8s v1.32.9 on Ubuntu
- **Nodes**: 8-node HA cluster (3 control plane nodes: mullet, trout, whale)
  - Original nodes: mullet (Ubuntu 22.04), trout (Ubuntu 24.04), tuna (Ubuntu 24.04), whale (Ubuntu 22.04)
  - Dell R320 nodes (Ceph storage): gold (Ubuntu 24.04), squid (Ubuntu 24.04), puffer (Ubuntu 24.04), carp (Ubuntu 24.04)
- **LoadBalancer**: MetalLB with IP range 192.168.0.200-192.168.0.220
- **Storage**: Rook/Ceph distributed storage with 3-way replication across Dell R320 nodes (16TB total capacity)

### Key Components

- **ArgoCD**: GitOps deployment tool, self-managed via Helm
- **Rook/Ceph**: Distributed storage system with 3-way replication
- **Monitoring**: Prometheus stack with Grafana dashboards
- **PostgreSQL**: CloudNativePG operator managing PostgreSQL clusters
- **vLLM**: Self-hosted LLM inference on whale's RTX 2000 Ada GPU — OpenAI-compatible API at `192.168.0.218`
- **Harbor**: CNCF graduated container registry at `https://registry.verticon.com` (192.168.0.219) — Ceph S3-backed image storage, Trivy vulnerability scanning, RBAC
- **Storage Classes**:
  - `rook-ceph-block` (3-way replication, default for all workloads)
    sudo vi /etc/caddy/Caddyfile

### Service Access

- **Grafana**: https://grafana.verticon.com (192.168.0.201:80)
- **Prometheus**: https://prometheus.verticon.com (192.168.0.202:80)
- **AlertManager**: https://alertmanager.verticon.com (192.168.0.203:80)
- **Loki**: http://loki.verticon.com (192.168.0.220:80) — log aggregation

## Setup Instructions

### 1. Initial Cluster Setup

Building the kubernetes cluster consists of the following steps:

1. Install node hardware/machines/os
2. Install MicroK8s on each node
3. Create the cluster by joining nodes to a master node
4. Add initial set of services to the cluster with MicroK8s addons

### 2. Node Prerequisites

No special prerequisites required for Rook/Ceph storage nodes. The Dell R320 nodes use their internal 4TB drives for Ceph OSDs.

### 3. Core Addons

```bash
# Enable core addons
microk8s enable dns

# Pihole is reserving range 192.168.0.100-192.168.0.150
# Use 192.168.0.200-192.168.0.220 for load balancer
microk8s enable metallb:192.168.0.200-192.168.0.220
```

## ArgoCD GitOps Setup

### Initial Installation

```bash
# Install ArgoCD using Helm
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Self-manage ArgoCD via GitOps
kubectl apply -f argoCD-apps/argocd-self-managed.yaml
```

### Development Tools

> **Claude Code skill — trycycle**: The `trycycle` global skill has been moved from
> `~/.claude/skills/` to `~/special-tools/.claude/skills/`. It is only available when
> launching Claude Code with: `claude --add-dir ~/special-tools`

```bash
# Use devbox for development tools
devbox shell  # Provides argocd, k9s, python, uv, and all cluster tools

# Login to ArgoCD server
devbox run -- argocd-login

# Monitor cluster with k9s
k9s

# Python environment (uv-managed, venv auto-activated)
uv venv          # create .venv on first use (gitignored)
uv pip install <package>
python script.py
```

## Rook/Ceph Storage

Rook/Ceph provides distributed block storage with 3-way replication across the Dell R320 nodes (gold, squid, puffer, carp).

### Storage Resources

```bash
# Check Ceph cluster health
kubectl get cephcluster -n rook-ceph

# Check Ceph OSDs (one per node, 4 total)
kubectl get pods -n rook-ceph -l app=rook-ceph-osd

# Check storage classes
kubectl get storageclass rook-ceph-block

# Monitor Ceph status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
```

### Storage Capacity

- **Total**: 16TB (4 x 4TB drives)
- **Usable**: ~5.3TB (with 3-way replication)
- **Current Usage**: ~31GB (0.20%)

## Monitoring Stack

### Prometheus and Grafana Installation

```bash
# Install Prometheus stack
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/helm/prometheus-values.yaml \
  --create-namespace \
  --timeout 15m

# Get Grafana admin password
kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

## Kafka

Apache Kafka deployed via the Strimzi operator in KRaft mode (no ZooKeeper), managed by ArgoCD. 3 dual-role broker/controller nodes with `rook-ceph-block` persistent storage.

### Addresses

| Listener           | Address                                                     | Use                                       |
| ------------------ | ----------------------------------------------------------- | ----------------------------------------- |
| External (MetalLB) | `192.168.0.213:9094`                                        | kafkactl from workstation                 |
| Internal (cluster) | `kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9092` | in-cluster clients (e.g. Schema Registry) |

> Use the IP directly rather than the DNS name. Kafka clients connect to the bootstrap address first, then reconnect to individual broker IPs (`.206`, `.207`, `.208`) — DNS only covers the bootstrap hop.

### kafkactl setup (one-time)

```bash
mkdir -p ~/.config/kafkactl
cat > ~/.config/kafkactl/config.yml <<'YAML'
contexts:
  default:
    brokers:
      - 192.168.0.213:9094
current-context: default
YAML
```

### Common commands

```bash
# List topics
devbox run -- kafkactl get topics

# Describe a topic
devbox run -- kafkactl describe topic <topic-name>

# Create a topic
devbox run -- kafkactl create topic <topic-name> --partitions 3 --replication-factor 3

# Produce a message
devbox run -- kafkactl produce <topic-name> --value "hello"

# Consume messages
devbox run -- kafkactl consume <topic-name> --from-beginning
```

Or enter `devbox shell` once and drop the `devbox run --` prefix.

---

## Harbor — Container Registry

[Harbor](https://goharbor.io) is the CNCF graduated container registry deployed in the cluster. It extends Docker Distribution with RBAC, vulnerability scanning (Trivy), image signing, audit logging, and a web UI. Image data is stored in Ceph RGW (S3-compatible), metadata in CloudNativePG.

### Addresses

| Access | Address | Use |
|---|---|---|
| Web UI | https://registry.verticon.com | Browser — projects, users, scanning |
| Docker CLI | `registry.verticon.com` | `docker login / push / pull` |
| Internal (cluster) | `192.168.0.219:80` | In-cluster image pulls |

### Web UI

Open https://registry.verticon.com in a browser. Default admin credentials are set via the `harbor-credentials` K8s secret (created at deploy time via teller from Google Secret Manager).

```bash
# Retrieve admin password
kubectl get secret harbor-credentials -n harbor -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d
```

Key UI features:
- **Projects** — create projects to namespace image repositories (default `library` project is public)
- **Repositories** — browse pushed images and tags
- **Vulnerabilities** — Trivy scan results per image
- **Users / Robot accounts** — create robot accounts for CI/CD pipeline access
- **Replication** — mirror to/from external registries

### Pushing and Pulling Images

```bash
# Login
docker login registry.verticon.com

# Tag and push
docker tag myapp:latest registry.verticon.com/library/myapp:latest
docker push registry.verticon.com/library/myapp:latest

# Pull
docker pull registry.verticon.com/library/myapp:latest
```

For CI/CD pipelines, create a robot account in the Harbor UI (Administration → Robot Accounts) with push/pull permissions on the target project, then use the robot credentials:

```bash
docker login registry.verticon.com -u 'robot$ci-user' -p <robot-token>
```

### Status commands

```bash
# Show Harbor pod status
just harbor-status

# Run Harbor chainsaw health tests
just test-harbor
```

### ArgoCD app

- **App-of-apps**: `harbor-apps` in ArgoCD
- **Child apps**: `harbor-storage` (wave 1), `harbor-database` (wave 2), `harbor` (wave 3)
- **Chart**: `harbor` `1.15.1` from `https://helm.goharbor.io`
- **Values**: `harbor-gitops/helm/harbor-values.yaml`
- **Namespace**: `harbor`

### Storage

| Component | Backend | Details |
|---|---|---|
| Image data | Ceph RGW S3 | Bucket `harbor-registry`, user `harbor-registry-user` |
| Metadata DB | CloudNativePG | Database `harbor`, role `harbor` on `production-postgresql` |
| Redis cache | Rook/Ceph block | PVC `data-harbor-redis-0`, 1Gi |
| Trivy DB | Rook/Ceph block | PVC `data-harbor-trivy-0`, 5Gi |

### Documentation

- **Official docs**: https://goharbor.io/docs/2.11.0/
- [Working with Projects](https://goharbor.io/docs/2.11.0/working-with-projects/) — create projects, push/pull, robot accounts
- [Administration](https://goharbor.io/docs/2.11.0/administration/) — users, LDAP, webhooks, replication
- [Vulnerability Scanning](https://goharbor.io/docs/2.11.0/administration/vulnerability-scanning/) — Trivy config

### Secrets bootstrap (one-time, on fresh deploy)

See `scripts/README.md` — Harbor secrets section. Requires `harbor-role`, `harbor-admin`, and `harbor-secret-key` (exactly 16 chars) in Google Secret Manager before running teller.

The Ceph S3 credentials (`harbor-s3-credentials`) must be copied manually from the Rook-generated secret after the `CephObjectStoreUser` reconciles:

```bash
CEPH_SECRET="rook-ceph-object-user-rook-ceph-rgw-harbor-registry-user"
ACCESS_KEY=$(kubectl get secret $CEPH_SECRET -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)
SECRET_KEY=$(kubectl get secret $CEPH_SECRET -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)
kubectl create secret generic harbor-s3-credentials \
  --namespace harbor \
  --from-literal=REGISTRY_STORAGE_S3_ACCESSKEY="$ACCESS_KEY" \
  --from-literal=REGISTRY_STORAGE_S3_SECRETKEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## Loki Log Aggregation

[Grafana Loki](https://grafana.com/oss/loki/) is a horizontally scalable, multi-tenant log aggregation system. It is deployed in monolithic single-binary mode in the `loki` namespace, with Ceph RGW S3 as the log chunk backend.

- **Service URL**: http://loki.verticon.com (Caddy proxies from mullet)
- **Direct IP**: http://192.168.0.220
- **Grafana integration**: available in the Explore tab → Loki datasource
- **Log sources**: all 8 cluster nodes (pod logs + OS syslog + systemd journal), external machines via Promtail systemd service

### LogQL query examples

```
# All logs from the harbor namespace containing "error"
{namespace="harbor"} |= "error"

# Logs from the puffer node containing "Power key"
{node="puffer"} |= "Power key"

# Syslog from gold node containing NVMe events
{job="syslog", node="gold"} |= "nvme"
```

### Caddyfile entry (mullet)

Add to `/etc/caddy/Caddyfile` on mullet:

```
loki.verticon.com {
    reverse_proxy 192.168.0.220:80
    request_body {
        max_size 0
    }
    tls {
        resolvers 1.1.1.1 1.0.0.1
    }
}
```

`max_size 0` disables Caddy's body size limit for log ingestion (Promtail external agents send bulk pushes).

### External Promtail install (mudshark/oyster/minnow)

For non-cluster Ubuntu machines, use the install script to ship syslog and journal to Loki:

```bash
# Copy scripts/promtail-external/ to the machine, then:
sudo bash scripts/promtail-external/install.sh <hostname>
# e.g.:  sudo bash install.sh mudshark
```

See `scripts/promtail-external/install.sh` for full installation details.

---

## vLLM — Self-Hosted LLM Inference

vLLM deployed via the [production-stack](https://github.com/vllm-project/production-stack) Helm chart, managed by ArgoCD. Runs `Qwen/Qwen2.5-7B-Instruct-AWQ` (INT4 quantized, ~4 GiB VRAM) on whale's RTX 2000 Ada GPU (16 GB VRAM).

### Model

| Field         | Value                             |
| ------------- | --------------------------------- |
| Model         | `Qwen/Qwen2.5-7B-Instruct-AWQ`    |
| Quantization  | AWQ INT4                          |
| Max context   | 8192 tokens                       |
| GPU           | RTX 2000 Ada (16 GB) on `whale`   |
| VRAM usage    | ~4 GiB model + ~9 GiB KV cache    |

### Addresses

| Access          | Address                                                  | Use                              |
| --------------- | -------------------------------------------------------- | -------------------------------- |
| External (MetalLB) | `http://192.168.0.218/v1`                             | API calls from workstation       |
| Internal (cluster) | `http://vllm-router-service.vllm.svc.cluster.local/v1` | in-cluster clients             |

### API Access

The API is OpenAI-compatible. Use `192.168.0.218` as the base URL — no API key required on the local network.

```bash
# List available models
curl http://192.168.0.218/v1/models | jq .

# Health check
curl http://192.168.0.218/health

# Chat completion
curl http://192.168.0.218/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-7B-Instruct-AWQ",
    "messages": [{"role": "user", "content": "What is the capital of France?"}],
    "max_tokens": 100,
    "temperature": 0.7
  }' | jq .choices[0].message.content
```

**Python (OpenAI SDK):**

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://192.168.0.218/v1",
    api_key="none",  # no auth required
)

response = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct-AWQ",
    messages=[{"role": "user", "content": "What is the capital of France?"}],
    max_tokens=100,
    temperature=0.7,
)
print(response.choices[0].message.content)
```

### Status commands

```bash
# Show vLLM pod placement and status
just vllm-status

# Run vLLM chainsaw tests (ArgoCD health, pod, /health, /v1/models, chat)
just test-vllm
```

### ArgoCD app

- **App**: `vllm` in ArgoCD
- **Chart**: `vllm-stack` from `https://vllm-project.github.io/production-stack`
- **Values**: `vllm-gitops/helm/vllm-values.yaml`
- **Namespace**: `vllm`

---

## Restic Backups

Automated incremental backups of `/home/jconlon` to Ceph RGW object storage using [Restic](https://restic.readthedocs.io/). Implemented in [issue #18](https://github.com/jconlon/ops-microk8s/issues/18).

### Overview

- **Repository**: `s3:http://192.168.0.204/restic-backups` (Ceph RGW)
- **Source**: `/home/jconlon` (excludes Music, Downloads, caches, build artifacts)
- **Secrets**: Injected at runtime via teller from Google Secret Manager — no credentials on disk
- **Teller config**: `~/dotfiles/restic/restic/.teller-restic-ceph.yml`

### Schedule

| Operation  | Schedule                | Purpose                                   |
| ---------- | ----------------------- | ----------------------------------------- |
| **Backup** | Daily at 3:00 AM        | Incremental backup                        |
| **Prune**  | Sunday at 4:00 AM       | Remove old snapshots, reclaim space       |
| **Verify** | 1st of month at 5:00 AM | Repository integrity check (5% data read) |

All timers have `Persistent=true` — if the machine was off at the scheduled time, the job runs shortly after boot.

### Retention Policy

```
--keep-hourly 24    # last 24 hours
--keep-daily 7      # last 7 days
--keep-weekly 4     # last 4 weeks
--keep-monthly 6    # last 6 months
--keep-yearly 2     # last 2 years
```

### Installation

```bash
cd scripts/restic/systemd
sudo ./install-restic.sh
```

### Verification and Management

```bash
# Check timer schedule and next run times
systemctl list-timers restic-*

# Check service status
systemctl status restic-backup.service

# View logs
tail -f /var/log/restic-backup.log
tail -f /var/log/restic-prune.log
tail -f /var/log/restic-verify.log

# Manual runs
sudo systemctl start restic-backup.service
sudo systemctl start restic-prune.service
sudo systemctl start restic-verify.service

# List recent snapshots
cd ~/dotfiles
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml run -- restic snapshots --latest 5

# Check repository size
devbox run -- teller --config restic/restic/.teller-restic-ceph.yml run -- restic stats --mode restore-size
```

See [`scripts/restic/systemd/README-restic.md`](scripts/restic/systemd/README-restic.md) for full documentation including troubleshooting and uninstall.

## Project Structure

```
ops-microk8s/
├── README.md                        # This documentation
├── CLAUDE.md                        # Claude Code instructions and guidance
├── justfile                         # Task runner (just test, just harbor-status, etc.)
├── devbox.json                      # Dev environment (argocd, k9s, kafkactl, kcat, chainsaw, python, uv)
├── ops                              # Nushell script wrapper (ops argocd / freshrss / kafka / cluster)
│
├── scripts/                         # See scripts/README.md for full details
│   ├── README.md                    # Scripts index and usage guide
│   ├── argocd.nu                    # ArgoCD management commands
│   ├── cluster.nu                   # Cluster health/uptime via Prometheus
│   ├── freshrss.nu                  # FreshRSS DB access and feed generation
│   ├── kafka.nu                     # Kafka Schema Registry commands
│   ├── sync-music-to-ceph.sh        # Sync ~/Music to Ceph RGW
│   ├── sync-pictures-to-ceph.sh     # Sync ~/Pictures to Ceph RGW
│   ├── systemd/                     # Systemd units for sync jobs
│   └── restic/                      # Restic backup scripts and systemd units
│
├── teller/                          # Teller configs — pull secrets from GSM → K8s
│   ├── .teller-freshrss.yml
│   ├── .teller-harbor.yml
│   ├── .teller-hasura.yml
│   ├── .teller-pgadmin.yml
│   ├── .teller-postgresql.yml
│   ├── .teller-vllm.yml
│   └── .teller-wallabag.yml
│
├── tests/                           # Chainsaw e2e tests (run via: just test)
│   ├── argocd/
│   ├── cluster/
│   ├── gpu/
│   ├── harbor/
│   ├── postgresql/
│   ├── storage/
│   └── vllm/
│
├── argoCD-apps/                     # ArgoCD application definitions
│   ├── argocd-self-managed.yaml
│   ├── cosmo-apps.yaml
│   ├── freshrss-apps.yaml
│   ├── gpu-operator-app.yaml
│   ├── harbor-apps.yaml
│   ├── hasura-apps.yaml
│   ├── kafka-apps.yaml
│   ├── kured-app.yaml
│   ├── monitoring-apps.yaml
│   ├── postgresql-apps.yaml
│   ├── rssbridge-app.yaml
│   ├── vllm-app.yaml
│   ├── wallabag-apps.yaml
│   ├── cosmo/
│   ├── freshrss/
│   ├── harbor/                      # harbor-storage, harbor-db, harbor (sync-waves 1-3)
│   ├── hasura/
│   ├── kafka/
│   ├── monitoring/
│   ├── postgresql/
│   ├── rook-ceph-apps/
│   └── wallabag/
│
├── harbor-gitops/                   # Harbor container registry
│   ├── helm/harbor-values.yaml      # Helm values (Ceph S3, external PG, MetalLB)
│   ├── database/harbor-database.yaml
│   └── storage/harbor-registry-user.yaml  # CephObjectStoreUser
│
├── kafka-gitops/                    # Strimzi Kafka
│   ├── helm/                        # Strimzi operator Helm values
│   ├── cluster/                     # KafkaNodePool + Kafka cluster manifests
│   └── schema-registry/             # Schema Registry Helm values
│
├── cosmo-gitops/                    # Cosmo GraphQL router
│   ├── app/
│   └── config/
│
├── hasura-gitops/                   # Hasura GraphQL engine
│   ├── app/
│   └── database/
│
├── freshrss/                        # FreshRSS RSS reader
│   ├── helm/
│   └── database/
│
├── vllm-gitops/                     # vLLM inference server
│   └── helm/vllm-values.yaml
│
├── gpu-operator-gitops/             # NVIDIA GPU operator
│
├── kured-gitops/                    # Kured automated node reboots
│   ├── helm/
│   └── node-setup/
│
├── rssbridge-gitops/                # RSS-Bridge
│
├── wallabag-gitops/                 # Wallabag read-later
│
├── monitoring/                      # Prometheus/Grafana/AlertManager Helm values
│   └── helm/
│       ├── prometheus-only-values.yaml
│       ├── grafana-only-values.yaml
│       └── alertmanager-only-values.yaml
│
├── rook-ceph/                       # Rook/Ceph storage
│   ├── cluster/                     # CephCluster + toolbox
│   ├── helm/                        # Rook operator Helm values
│   ├── monitoring/
│   ├── object-storage/              # CephObjectStore + CephObjectStoreUsers
│   └── storageclasses/
│
└── postgresql-gitops/               # CloudNativePG
    ├── cluster/                     # Cluster definition + managed roles
    ├── backup/                      # ScheduledBackup to Ceph S3
    ├── monitoring/
    └── networking/                  # LoadBalancer services (primary + readonly)
```

## Adding a New DNS Name for a Service

When deploying a new service with a MetalLB LoadBalancer IP, follow these steps to expose it at a `verticon.com` hostname.

### 1. Add DNS record in Cloudflare

[Cloudflare Console](https://dash.cloudflare.com/login)

Add an `A` record in the Cloudflare dashboard to point to mullet's IP:

| Type | Name        | Content         | Proxy Status           |
| ---- | ----------- | --------------- | ---------------------- |
| A    | `<service>` | `192.168.0.101` | DNS only - reserved IP |

### 2. Configure Caddy reverse proxy

```bash
# on mullet
sudo vi /etc/caddy/Caddyfile
```

Add a new block:

```
<service>.verticon.com {
    reverse_proxy 192.168.0.2xx:80
    tls {
        resolvers 1.1.1.1 1.0.0.1
    }
}

```

### 3. Reload Caddy

```bash
systemctl reload caddy
```

Caddy handles TLS automatically via Let's Encrypt. No restart required — `reload` is zero-downtime.

### Existing service hostnames

| Service               | Hostname                          | MetalLB IP    |
| --------------------- | --------------------------------- | ------------- |
| Grafana               | https://grafana.verticon.com      | 192.168.0.201 |
| Prometheus            | https://prometheus.verticon.com   | 192.168.0.202 |
| AlertManager          | https://alertmanager.verticon.com | 192.168.0.203 |
| PostgreSQL (primary)  | —                                 | 192.168.0.210 |
| PostgreSQL (readonly) | —                                 | 192.168.0.211 |
| pgAdmin               | https://pgadmin.verticon.com      | 192.168.0.212 |
| Harbor (registry)     | https://registry.verticon.com     | 192.168.0.219 |
| vLLM (OpenAI API)     | —                                 | 192.168.0.218 |

---

## Troubleshooting

### Common Issues

#### Ceph Health Checks

```bash
# Check Ceph cluster health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Check OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status

# Check PG status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat
```

### Useful Commands

```bash
# Check cluster status
microk8s status
kubectl get nodes

# Check Ceph storage status
kubectl get cephcluster -n rook-ceph
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
kubectl get pods -n rook-ceph

# Monitor storage
kubectl get pv,pvc --all-namespaces
kubectl get storageclass

# Check monitoring stack
kubectl get pods -n monitoring
kubectl get servicemonitors,prometheusrules --all-namespaces

# Check PostgreSQL cluster
kubectl get cluster -n postgresql-system
kubectl get pods -n postgresql-system

# ArgoCD operations
devbox run -- argocd app list
devbox run -- argocd app sync <app-name>
```

### Development Environment

```bash
# Enter development shell with tools
devbox shell

# Available tools:
# - argocd: ArgoCD CLI
# - k9s: Kubernetes cluster management
# - kubectl: Kubernetes CLI
# - python / uv: Python runtime + package manager (venv auto-activated)
# - nu: Nushell for ops scripts
# - psql / barman: PostgreSQL CLI tools
# - teller: Secret injection from Google Secret Manager
# - kafkactl / kcat: Kafka CLI tools
# - chainsaw: Kyverno e2e test runner
```

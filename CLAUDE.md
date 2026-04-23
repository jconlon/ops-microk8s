# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## System Prompt: Startup, Global–Project Memory, and User Identification

For every Claude Code session in this project, follow these startup steps in order:

1. **User Identification (Global Memory)**

   - Retrieve user identification from global memory (via the memory MCP persistent store).
   - If "jconlon" is not already identified as the default_user in global memory, add or update this entity accordingly.
   - Throughout all interactions, treat "jconlon" as the default_user.

2. **Global Memory Retrieval**

   - Say "Remembering global memory..." and retrieve all relevant information from the global memory store (via memory MCP server).
   - When discussing persistent rules or reusable procedures, specify that these come from global memory.

3. **Project Memory Retrieval**

   - Say "Remembering project memory..." and load all project-specific context from the "Memories" section of this CLAUDE.md.
   - When referencing local workflows, specific script usage, infrastructure, or sensitive details, make clear these originate solely from project memory.

4. **Memory Context Usage**
   - When providing answers or executing tasks, always clarify which memory source (global or project) the information is from:
     - e.g., "According to global memory..." or "From project memory..."
   - If it is ever unclear where new information belongs, ask:  
     “Should this be remembered globally (across all projects) or for this project only?”

5. **Scripts Reference**
   - Read `scripts/README.md` to load the current list of available scripts, their purpose, and usage.
   - When asked about available scripts or how to run an operation, consult `scripts/README.md` first.

Please follow these memory protocols at the beginning of each Claude Code session or chat in this repository. Refer to the [Memory Integration Protocol](#memory-integration-protocol), [Memories](#memories), and [Global Persistent Memory (via Memory MCP)](#global-persistent-memory-via-memory-mcp) sections below for operational details.

## Repository Overview

This repository contains the infrastructure configuration for a MicroK8s cluster with 8 nodes: mullet, trout, tuna, whale, gold, squid, puffer, and carp. The cluster uses Rook/Ceph for distributed replicated storage. Monitoring is provided by Prometheus/Grafana.

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
- **Kafka**: Strimzi operator, 3-broker KRaft cluster (no ZooKeeper), `kafka-system` namespace
  - External (MetalLB): `192.168.0.213:9094` — use IP, not DNS (broker reconnect requires it)
  - Internal: `kafka-kafka-bootstrap.kafka-system.svc.cluster.local:9092`
  - Schema Registry: running in `kafka-system`, backed by PostgreSQL
- **Loki**: Grafana Loki log aggregation at 192.168.0.220 (`loki` namespace) — all pod logs + OS syslog; Grafana datasource at http://loki-gateway.loki.svc:80
- **Storage Classes**:
  - `rook-ceph-block` (3-way replication, default for all workloads)

## Development Commands

### Cluster Management

```bash
# Check cluster status
microk8s status
kubectl get nodes

# Enable core addons
microk8s enable dns
microk8s enable metallb:192.168.0.200-192.168.0.220
```

### ArgoCD Deployment

> **Note**: All Helm deployments are managed by ArgoCD. Never run `helm` directly.

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Self-manage ArgoCD
kubectl apply -f argoCD-apps/argocd-self-managed.yaml
```

### Rook/Ceph Storage

```bash
# Check Ceph cluster health
kubectl get cephcluster -n rook-ceph

# Check Ceph status via toolbox
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# View storage classes
kubectl get storageclass rook-ceph-block

# Monitor Ceph OSDs
kubectl get pods -n rook-ceph -l app=rook-ceph-osd
```

### Kafka

```bash
# List topics
kafkactl get topics

# Describe a topic
kafkactl describe topic <topic-name>

# Create a topic (3 partitions, 3-way replication)
kafkactl create topic <topic-name> --partitions 3 --replication-factor 3

# Produce / consume
kafkactl produce <topic-name> --value "hello"
kafkactl consume <topic-name> --from-beginning

# Schema Registry — external: https://192.168.0.214:8081
curl -s http://192.168.0.214:8081/subjects | jq
curl -s http://192.168.0.214:8081/subjects/<subject>/versions/latest | jq

# Check Schema Registry pod
kubectl get pods -n kafka-system -l app=schema-registry
```

### Monitoring Stack

> **Note**: Monitoring stack is deployed via ArgoCD. See `argoCD-apps/monitoring-apps.yaml`.

```bash
# Get Grafana admin password
kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d
```

### Development Environment

> **Note**: Claude Code sessions always run inside the devbox shell. All devbox tools (`argocd`, `k9s`, `nu`, `psql`, `python`, `uv`, etc.) are available directly without `devbox run --` prefixes.

```bash
# Monitor cluster with k9s
k9s

# Python environment (uv-managed venv, auto-activated by devbox init_hook)
uv venv          # create .venv on first use
uv pip install   # install packages into .venv
python           # Python from devbox, venv active
```

> **Python venv**: `VENV_DIR` is set to `.venv` in the repo root. The devbox `init_hook` activates it automatically if it exists. The `.venv/` directory is gitignored.

## Important Configuration Details

### MicroK8s Specifics

- **Kubelet Directory**: `/var/snap/microk8s/common/var/lib/kubelet/` (configured in Helm values)
- **Ceph Toolbox**: Use `kubectl exec -n rook-ceph deploy/rook-ceph-tools` to run Ceph commands

### Node Prerequisites

Each Ubuntu node requires:

```bash
# HugePages configuration
sudo sysctl vm.nr_hugepages=1024
echo 'vm.nr_hugepages=1024' | sudo tee -a /etc/sysctl.conf

# NVMe modules
sudo modprobe nvme_tcp
echo 'nvme-tcp' | sudo tee -a /etc/modules-load.d/microk8s.conf
```

### Service Access

- **Grafana**: https://grafana.verticon.com (192.168.0.201:80)
- **Prometheus**: https://prometheus.verticon.com (192.168.0.202:80)
- **AlertManager**: https://alertmanager.verticon.com (192.168.0.203:80)
- **Loki**: http://loki.verticon.com (192.168.0.220:80)
- **iDRAC Syslog**: 192.168.0.209:1514/UDP — MetalLB LoadBalancer for iDRAC syslog from Dell R320 nodes (gold, squid, puffer, carp) into Loki (`job="idrac"`)

## File Structure

```
ops-microk8s/
├── README.md                     # Detailed setup documentation
├── CLAUDE.md                     # Claude Code instructions and guidance
├── devbox.json                   # Development environment (argocd, k9s, python, uv)
├── scripts/                      # See scripts/README.md for full details
│   ├── README.md                 # Scripts index and usage guide
│   ├── argocd.nu                 # ArgoCD management commands (nushell)
│   ├── freshrss.nu               # FreshRSS DB access via psql (nushell)
│   ├── sync-music-to-ceph.sh     # Sync ~/Music to Ceph RGW
│   ├── sync-pictures-to-ceph.sh  # Sync ~/Pictures to Ceph RGW
│   ├── systemd/                  # Systemd units for sync jobs
│   └── restic/                   # Restic backup scripts and systemd units
├── teller/                       # Teller configs for cluster K8s secret management
│   ├── .teller-freshrss.yml      # FreshRSS secrets (Google Secret Manager → K8s)
│   └── .teller-postgresql.yml    # PostgreSQL backup S3 credentials
├── argoCD-apps/                  # ArgoCD application definitions
│   ├── argocd-self-managed.yaml
│   ├── monitoring-apps.yaml     # App of Apps for monitoring stack
│   ├── monitoring/              # Child applications for monitoring
│   │   ├── prometheus-app.yaml
│   │   ├── grafana-app.yaml
│   │   └── alertmanager-app.yaml
│   ├── rook-ceph-apps/          # App of Apps for Rook/Ceph
│   │   ├── rook-ceph-root.yaml
│   │   ├── rook-operator-app.yaml
│   │   ├── ceph-cluster-app.yaml
│   │   ├── ceph-storageclasses-app.yaml
│   │   └── ceph-monitoring-app.yaml
│   └── postgresql/              # PostgreSQL ArgoCD apps
│       ├── postgresql-operator.yaml
│       ├── postgresql-cluster.yaml
│       ├── postgresql-monitoring.yaml
│       └── postgresql-networking.yaml
├── monitoring/                   # Split monitoring stack configurations
│   └── helm/
│       ├── prometheus-only-values.yaml    # Prometheus + operator + exporters
│       ├── grafana-only-values.yaml       # Grafana standalone config
│       └── alertmanager-only-values.yaml  # AlertManager standalone config
├── rook-ceph/                   # Rook/Ceph storage configurations
│   ├── cluster/                 # Ceph cluster and toolbox
│   ├── helm/                    # Rook operator Helm values
│   ├── monitoring/              # Ceph monitoring (Grafana, Prometheus, ServiceMonitor)
│   └── storageclasses/          # Storage class and block pool definitions
└── postgresql-gitops/           # PostgreSQL configurations
    ├── cluster/                 # PostgreSQL cluster definitions
    ├── monitoring/              # PostgreSQL monitoring
    └── networking/              # PostgreSQL services
```

## Troubleshooting

### Common Issues

1. **Ceph health warnings**: Check OSD status and replication
2. **Volume mount failures**: Verify Ceph cluster health
3. **Storage provisioning issues**: Ensure storage class and block pool exist
4. **Network connectivity**: Verify MetalLB IP range doesn't conflict with PiHole

### Useful Commands

```bash
# Check Ceph status
kubectl get cephcluster -n rook-ceph
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Monitor storage
kubectl get pv,pvc --all-namespaces
kubectl get storageclass

# Check monitoring stack
kubectl get pods -n monitoring
kubectl get servicemonitors,prometheusrules --all-namespaces
```

## Memory Integration Protocol

- On startup, perform user identification from global memory (see steps above).
- Next, load and review all global memory for persistent context, and then project memory for repository-local instructions and facts.
- Use the **Memories** section (see below) for all instructions, settings, and workflow items unique to this project.
- Use global persistent memory (via the `memory` MCP server) for cross-project or organization-wide information, such as recurring procedures or general preferences.
- If there is any doubt about the scope of a memory, clarify with the user before storing or retrieving it.  
  _Example: "Should this be global or project specific?"_
- Always reference both memories when answering or planning.

_When updating or storing new items, clearly state whether you’re updating project memory (Memories section) or global persistent memory (via MCP)._

---

## Memories

_Project-specific instructions and facts—use only within this repository:_

- Always use context7 MCP server to find latest documentation info.
- Set the timeout for executing Bash commands to 10 minutes.
- When asked to show or get files, open them in VS Code using `code` command.
- When asked to get or fetch a command use `xclip` to copy the command to memory.
- **Claude Code sessions always run inside the devbox shell.** All tools (`argocd`, `psql`, `nu`, `k9s`, etc.) are available directly — never use `devbox run --` prefixes.
- To login to ArgoCD server use the command: `ops argocd login`
- Always login to ArgoCD server at the start of all sessions.
- All argocd commands use the `ops argocd` wrapper: e.g. `ops argocd list-app`
- **For checking cluster state, prefer `just` recipes and chainsaw tests over raw kubectl:**
  - `just test` — run all e2e health checks (nodes, ceph, gpu, postgresql, argocd)
  - `just test-suite <suite>` — run a single suite: `cluster`, `storage`, `gpu`, `postgresql`, `argocd`
  - `just node-status` — node uptime + reboot-required
  - `just ceph-status` — Ceph cluster health
  - `just pg-status` — CloudNativePG cluster status
  - `just gpu-status` — GPU allocatable resources on whale
  - `just pods-unhealthy` — all non-running pods cluster-wide
  - Use raw `kubectl` only for queries not covered by the above.
- For troubleshooting, use kubectl krew tools listed in `kubectl_krew_commands.md`. Run `kubectl plugin list` at startup to confirm available plugins.
- When connecting to verticon.com servers use https not http.
- To get ArgoCD password:  
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- ArgoCD username is `admin`
- For postgresql cli use: `psql`
- The `kubectl cnpg` plugin is available for CloudNativePG management. Example: `kubectl cnpg status production-postgresql -n postgresql-system`
- For available scripts and usage, read `scripts/README.md` at session start.
- To connect to the FreshRSS database use: `ops freshrss psql`
- Cluster teller configs are in `teller/` directory (not in ~/dotfiles). Use `teller/` prefix for all cluster K8s secret operations. Run from ops-microk8s directory.
- NEVER run `helm repo add` or `helm repo update` locally. Helm charts are managed entirely by ArgoCD using `repoURL` and `chart` fields in ArgoCD Application manifests. There is no need to add repos to the local Helm installation.

---

## Global Persistent Memory (via Memory MCP)

_Cross-project, persistent knowledge and identification for usage in all Claude projects:_

- User identification: The default_user is "jconlon".
- For all global procedures, organizational policies, or personal preferences needed across repositories, store and recall them in global memory via the memory MCP persistent store.
- To add or update a global memory, say or type:  
  `Add to global memory: <your fact, rule, or process>`
- When retrieving information, always check both project memory (Memories) and global memory for relevant context.
- If you are uncertain about memory scope, clarify:  
  “Is this for this project only or for global memory?”
- Examples of global memory items:
  - "Always rotate credentials every 90 days."
  - "After each release, update CHANGELOG and deployment checklist."
  - "Default user is jconlon; treat jconlon as owner in all sessions."

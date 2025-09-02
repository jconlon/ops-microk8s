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

Please follow these memory protocols at the beginning of each Claude Code session or chat in this repository. Refer to the [Memory Integration Protocol](#memory-integration-protocol), [Memories](#memories), and [Global Persistent Memory (via Memory MCP)](#global-persistent-memory-via-memory-mcp) sections below for operational details.

## Repository Overview

This repository contains the infrastructure configuration for a MicroK8s cluster with 5 nodes: mullet, shamu, trout, tuna, and whale. The cluster uses OpenEBS Mayastor for replicated storage and includes monitoring with Prometheus/Grafana.

## Architecture

### Cluster Configuration

- **Platform**: MicroK8s v1.32.3 on Ubuntu
- **Nodes**: 5-node HA cluster (3 control plane nodes: mullet, trout, whale)
- **LoadBalancer**: MetalLB with IP range 192.168.0.200-192.168.0.220
- **Storage**: OpenEBS Mayastor with external 4TB drives on each node

### Key Components

- **ArgoCD**: GitOps deployment tool, self-managed via Helm
- **OpenEBS**: Storage management with Mayastor engine for replicated volumes
- **Monitoring**: Prometheus stack with Grafana dashboards
- **Storage Classes**:
  - `mayastor-monitoring-ha` (3 replicas)
  - `mayastor-monitoring-balanced` (2 replicas)

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

```bash
# Initial ArgoCD installation
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Self-manage ArgoCD
kubectl apply -f argoCD-apps/argocd-self-managed.yaml
```

### OpenEBS Mayastor

```bash
# Install OpenEBS with Mayastor
helm upgrade --install openebs openebs/openebs \
  --namespace openebs \
  --values openebs-gitops/helm/openebs-mayastor-values.yaml \
  --create-namespace \
  --timeout 15m

# Label nodes for Mayastor
kubectl label node whale openebs.io/engine=mayastor
kubectl label node tuna openebs.io/engine=mayastor
kubectl label node trout openebs.io/engine=mayastor
kubectl label node shamu openebs.io/engine=mayastor
kubectl label node mullet openebs.io/engine=mayastor

# Apply diskpools
kubectl apply -f openebs-gitops/diskpools/
kubectl apply -f openebs-gitops/storageclasses/mayastor-storage-classes.yaml
```

### Monitoring Stack

```bash
# Install Prometheus stack
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/helm/prometheus-values.yaml \
  --create-namespace \
  --timeout 15m

# Get Grafana admin password
kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d

# Apply OpenEBS monitoring configurations
kubectl apply -f openebs-gitops/monitoring/
```

### Development Environment

```bash
# Use devbox for development tools
devbox shell  # Provides argocd and k9s

# Monitor cluster with k9s
k9s
```

## Important Configuration Details

### MicroK8s Specifics

- **Kubelet Directory**: `/var/snap/microk8s/common/var/lib/kubelet/` (configured in Helm values)
- **IOVA Mode**: Mayastor requires `--iova-mode=pa` for io-engine pods

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

## File Structure

```
ops-microk8s/
├── README.md                     # Detailed setup documentation
├── CLAUDE.md                     # Claude Code instructions and guidance
├── devbox.json                   # Development environment (argocd, k9s)
├── scripts/
│   └── argocd.nu                 # ArgoCD login script (nushell)
├── argoCD-apps/                  # ArgoCD application definitions
│   ├── argocd-self-managed.yaml
│   ├── monitoring-apps.yaml     # App of Apps for monitoring stack
│   ├── monitoring/              # Child applications for monitoring
│   │   ├── prometheus-app.yaml
│   │   ├── grafana-app.yaml
│   │   └── alertmanager-app.yaml
│   ├── openebs-apps/            # App of Apps for OpenEBS
│   │   ├── openebs-root.yaml
│   │   ├── openebs-mayastor.yaml
│   │   ├── openebs-diskpools.yaml
│   │   ├── openebs-storageclasses.yaml
│   │   └── openebs-monitoring.yaml
├── monitoring/                   # Split monitoring stack configurations
│   └── helm/
│       ├── prometheus-only-values.yaml    # Prometheus + operator + exporters
│       ├── grafana-only-values.yaml       # Grafana standalone config
│       └── alertmanager-only-values.yaml  # AlertManager standalone config
└── openebs-gitops/              # OpenEBS storage configurations
    ├── diskpools/               # Mayastor diskpool definitions per node
    ├── helm/
    │   └── openebs-mayastor-values.yaml  # Main OpenEBS Helm config
    ├── monitoring/              # OpenEBS monitoring configurations
    │   ├── grafana-config-map.yaml      # OpenEBS Grafana dashboards
    │   ├── openebs-prometheusrules.yaml # OpenEBS alerting rules
    │   └── openebs-servicemonitors.yaml # OpenEBS metrics collection
    └── storageclasses/          # Storage class definitions
```

## Troubleshooting

### Common Issues

1. **Mayastor io-engine pods failing**: Check IOVA mode configuration in DaemonSet
2. **Volume mount failures**: Verify kubelet directory path in Helm values
3. **Storage provisioning issues**: Ensure diskpools are created and healthy
4. **Network connectivity**: Verify MetalLB IP range doesn't conflict with PiHole

### Useful Commands

```bash
# Check Mayastor status
kubectl get pods -l app=io-engine -n openebs
kubectl get diskpools -n openebs

# Monitor storage
kubectl get pv,pvc --all-namespaces

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
- To login to ArgoCD server use the command: `devbox run -- argocd-login`
- Always login to ArgoCD server at the start of all sessions.
- All argocd commands should be run with this prefix: `devbox run -- argocd`
- For troubleshooting, use any kubectl krew tools specified in: kubectl_krew_commands.md
- When connecting to verticon.com servers use https not http.
- To get ArgoCD password:  
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`
- ArgoCD username is `admin`
- For postgresql cli use: `devbox run psql`

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

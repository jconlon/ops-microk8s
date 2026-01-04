# ops-microk8s

Infrastructure configuration for a MicroK8s cluster with 8 nodes: mullet, trout, tuna, whale, gold, squid, puffer, and carp. The cluster currently uses OpenEBS Mayastor for replicated storage and is migrating to Rook/Ceph. Monitoring is provided by Prometheus/Grafana.

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

- **Platform**: MicroK8s v1.32.3 on Ubuntu
- **Nodes**: 8-node HA cluster (3 control plane nodes: mullet, trout, whale)
  - Original nodes (Mayastor): mullet (Ubuntu 22.04), trout (Ubuntu 24.04), tuna (Ubuntu 24.04), whale (Ubuntu 22.04)
  - Dell R320 nodes (Rook/Ceph migration): gold (Ubuntu 24.04), squid (Ubuntu 24.04), puffer (Ubuntu 24.04), carp (Ubuntu 24.04)
- **LoadBalancer**: MetalLB with IP range 192.168.0.200-192.168.0.220
- **Storage**:
  - Current: OpenEBS Mayastor with external 4TB drives on original nodes
  - Migration: Rook/Ceph on Dell R320 nodes to replace Mayastor

### Key Components

- **ArgoCD**: GitOps deployment tool, self-managed via Helm
- **OpenEBS**: Storage management with Mayastor engine for replicated volumes
- **Monitoring**: Prometheus stack with Grafana dashboards
- **Storage Classes**:
  - `mayastor-monitoring-ha` (3 replicas)
  - `mayastor-monitoring-balanced` (2 replicas)

### Service Access

- **Grafana**: https://grafana.verticon.com (192.168.0.201:80)
- **Prometheus**: https://prometheus.verticon.com (192.168.0.202:80)
- **AlertManager**: https://alertmanager.verticon.com (192.168.0.203:80)

## Setup Instructions

### 1. Initial Cluster Setup

Building the kubernetes cluster consists of the following steps:

1. Install node hardware/machines/os
2. Install MicroK8s on each node
3. Create the cluster by joining nodes to a master node
4. Add initial set of services to the cluster with MicroK8s addons

### 2. Node Prerequisites

Each Ubuntu node requires these configurations prior to installing OpenEBS and Mayastor:

```bash
# HugePages configuration
sudo sysctl vm.nr_hugepages=1024
echo 'vm.nr_hugepages=1024' | sudo tee -a /etc/sysctl.conf

# NVMe modules
sudo modprobe nvme_tcp
echo 'nvme-tcp' | sudo tee -a /etc/modules-load.d/microk8s.conf
```

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

```bash
# Use devbox for development tools
devbox shell  # Provides argocd and k9s

# Login to ArgoCD server
devbox run -- argocd-login

# Monitor cluster with k9s
k9s
```

## OpenEBS Mayastor Storage

### Installation

```bash
# Install OpenEBS with Mayastor
helm upgrade --install openebs openebs/openebs \
  --namespace openebs \
  --values openebs-gitops/helm/openebs-mayastor-values.yaml \
  --create-namespace \
  --timeout 15m
```

### Node Configuration

```bash
# Label original nodes for Mayastor (nodes with 4TB external drives)
kubectl label node mullet openebs.io/engine=mayastor
kubectl label node trout openebs.io/engine=mayastor
kubectl label node tuna openebs.io/engine=mayastor
kubectl label node whale openebs.io/engine=mayastor

# Note: Dell R320 nodes (gold, squid, puffer, carp) are reserved for Rook/Ceph migration

# Monitor io-engine pods
kubectl get pods -l app=io-engine -w
```

### Diskpools and Storage Classes

```bash
# Apply diskpools for each node
kubectl apply -f openebs-gitops/diskpools/

# Apply storage classes
kubectl apply -f openebs-gitops/storageclasses/mayastor-storage-classes.yaml
```

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

# Apply OpenEBS monitoring configurations
kubectl apply -f openebs-gitops/monitoring/
```

## Project Structure

```
ops-microk8s/
├── README.md                     # This documentation
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
│   └── openebs-apps/            # App of Apps for OpenEBS
│       ├── openebs-root.yaml
│       ├── openebs-mayastor.yaml
│       ├── openebs-diskpools.yaml
│       ├── openebs-storageclasses.yaml
│       └── openebs-monitoring.yaml
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

## OpenEBS Background

### Project Status

[OpenEBS roadmap](https://github.com/openebs/openebs/blob/main/ROADMAP.md) focuses on these engines in release +4.2:

1. LocalPV-HostPath
2. LocalPV-LVM
3. LocalPV-ZFS
4. Mayastor

Moving forward, the new OpenEBS product architecture centers around 2 core storage services: 'Local' and 'Replicated'.

## Troubleshooting

### Common Issues

#### Volume Mount Failures

MicroK8s requires custom kubelet directory configuration. This is handled in `openebs-gitops/helm/openebs-mayastor-values.yaml`:

```yaml
mayastor:
  csi:
    node:
      kubeletDir: /var/snap/microk8s/common/var/lib/kubelet/
```

#### IOVA Mode Issues

Mayastor io-engine pods require `--iova-mode=pa` parameter. This is configured in the Helm values:

```yaml
mayastor:
  io_engine:
    envcontext: "--iova-mode=pa"
```

### Useful Commands

```bash
# Check cluster status
microk8s status
kubectl get nodes

# Check Mayastor status
kubectl get pods -l app=io-engine -n openebs
kubectl get diskpools -n openebs

# Monitor storage
kubectl get pv,pvc --all-namespaces

# Check monitoring stack
kubectl get pods -n monitoring
kubectl get servicemonitors,prometheusrules --all-namespaces

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
```
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
- **Storage Classes**:
  - `rook-ceph-block` (3-way replication, default for all workloads)

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

```bash
# Use devbox for development tools
devbox shell  # Provides argocd and k9s

# Login to ArgoCD server
devbox run -- argocd-login

# Monitor cluster with k9s
k9s
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
```
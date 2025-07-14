# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- **Grafana**: http://grafana.verticon.com (192.168.0.201:80)
- **Prometheus**: http://prometheus.verticon.com (192.168.0.202:80)  
- **AlertManager**: http://alertmanager.verticon.com (192.168.0.203:80)

## File Structure

```
ops-microk8s/
├── README.md                     # Detailed setup documentation
├── argoCD-apps/                  # ArgoCD application definitions
│   ├── argocd-self-managed.yaml
│   └── mayastor-app.yaml
├── devbox.json                   # Development environment (argocd, k9s)
├── monitoring/                   # Prometheus/Grafana configurations
│   ├── helm/
│   │   └── prometheus-values.yaml  # Main monitoring stack config
│   └── manifests/               # Additional monitoring configs
└── openebs-gitops/              # OpenEBS storage configurations
    ├── diskpools/               # Mayastor diskpool definitions per node
    ├── helm/
    │   └── openebs-mayastor-values.yaml  # Main OpenEBS config
    ├── monitoring/              # OpenEBS monitoring rules
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
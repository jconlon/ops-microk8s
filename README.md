# ops-microk8s

Building the kubernetes cluster consists of the following steps:

1. Install node hardware/machines/os.
1. Install Microk8s on each node.
1. Create the cluster by joining nodes to a master node.
1. Add initial set of services to the cluster with Microk8s addons.

## Addons

```bash
 microk8s enable dns

# Pihole is reserving range  192.168.0.100-192.168.0.150
# Use 192.168.0.200-192.168.0.220 for load balancer
 microk8s enable metallb:192.168.0.200-192.168.0.220

```

## ArgoCD

```bash
# Helm first to get the correct values file
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace

# After reaching the UI the first time you can login with username: admin and the random password generated during the installation. You can find the password by running:

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Self managed via helm values
kubectl apply -f argoCD-apps/argocd-self-managed.yaml
```

## OpenEBS

```text
openebs-gitops/
├── apps/
│   ├── openebs-app.yaml
│   ├── mayastor-app.yaml
│   └── diskpools/
│       ├── mullet-pool.yaml
│       ├── whale-pool.yaml
│       └── ... # Pool manifests per node
├── root-app-of-apps.yaml



```

### Prerequisite

On each node

```bash
# HugePages

sudo sysctl vm.nr_hugepages=1024
echo 'vm.nr_hugepages=1024' | sudo tee -a /etc/sysctl.conf

# NVMe modules
sudo modprobe nvme_tcp
echo 'nvme-tcp' | sudo tee -a /etc/modules-load.d/microk8s.conf
```

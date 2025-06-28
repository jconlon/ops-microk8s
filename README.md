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

[Mayastor addon](https://microk8s.io/docs/addon-mayastor)

```bash
jconlon in 🌐 trout in ☸ microk8s in ~
sudo microk8s enable core/mayastor --default-pool-size 10G
[sudo] password for jconlon:
Checking for HugePages (>= 1024)...
Checking for HugePages (>= 1024)... OK
Checking for nvme_tcp module...
Checking for nvme_tcp module... OK
Checking for addon core/dns...
Checking for addon core/dns... OK
Checking for addon core/helm3...
Checking for addon core/helm3... OK
Error from server (AlreadyExists): namespaces "mayastor" already exists
Default image size set to 10G
Getting updates for unmanaged Helm repositories...
...Successfully got an update from the "https://raw.githubusercontent.com/canonical/etcd-operator/master/chart" chart repository
...Successfully got an update from the "https://github.com/canonical/mayastor-extensions/releases/download/v2.0.0-microk8s-1b" chart repository
Saving 2 charts
Downloading etcd-operator from repo https://raw.githubusercontent.com/canonical/etcd-operator/master/chart
Downloading mayastor from repo https://github.com/canonical/mayastor-extensions/releases/download/v2.0.0-microk8s-1b
Deleting outdated charts
NAME: mayastor
LAST DEPLOYED: Fri Jun 27 19:05:42 2025
NAMESPACE: mayastor
STATUS: deployed
REVISION: 1
TEST SUITE: None

=============================================================

Mayastor has been installed and will be available shortly.

Mayastor will run for all nodes in your MicroK8s cluster by default. Use the
'microk8s.io/mayastor=disable' label to disable any node. For example:

    microk8s.kubectl label node trout microk8s.io/mayastor=disable




```

### Problems

The io-engine pods will not start and will show this error:

```bash

k logs pod/mayastor-io-engine-p9hqr
Defaulted container "io-engine" out of: io-engine, agent-core-grpc-probe (init), etcd-probe (init), initialize-pool (init)
[2025-06-28T05:15:11.249136333+00:00  INFO io_engine:io-engine.rs:179] Engine responsible for managing I/Os version 1.0.0, revision b0734db654d8 (v2.0.0)
[2025-06-28T05:15:11.249274831+00:00  INFO io_engine:io-engine.rs:158] free_pages 2MB: 1024 nr_pages 2MB: 1024
[2025-06-28T05:15:11.249290891+00:00  INFO io_engine:io-engine.rs:159] free_pages 1GB: 0 nr_pages 1GB: 0
[2025-06-28T05:15:11.249374014+00:00  INFO io_engine:io-engine.rs:211] kernel io_uring support: yes
[2025-06-28T05:15:11.249393610+00:00  INFO io_engine:io-engine.rs:215] kernel nvme initiator multipath support: yes
[2025-06-28T05:15:11.249442393+00:00  INFO io_engine::core::env:env.rs:791] loading mayastor config YAML file /var/local/io-engine/config.yaml
[2025-06-28T05:15:11.249460891+00:00  INFO io_engine::subsys::config:mod.rs:168] Config file /var/local/io-engine/config.yaml is empty, reverting to default config
[2025-06-28T05:15:11.249465868+00:00  INFO io_engine::subsys::config::opts:opts.rs:151] Overriding NVMF_TCP_MAX_QUEUE_DEPTH value to '32'
[2025-06-28T05:15:11.249471280+00:00  INFO io_engine::subsys::config::opts:opts.rs:151] Overriding NVME_QPAIR_CONNECT_ASYNC value to 'true'
[2025-06-28T05:15:11.249478343+00:00  INFO io_engine::subsys::config:mod.rs:216] Applying Mayastor configuration settings
EAL: alloc_pages_on_heap(): couldn't allocate memory due to IOVA exceeding limits of current DMA mask
EAL: alloc_pages_on_heap(): Please try initializing EAL with --iova-mode=pa parameter
EAL: error allocating rte services array
EAL: FATAL: rte_service_init() failed
EAL: rte_service_init() failed
thread 'main' panicked at 'Failed to init EAL', io-engine/src/core/env.rs:628:13
stack backtrace:
   0: std::panicking::begin_panic
   1: io_engine::core::env::MayastorEnvironment::init
   2: io_engine::main
note: Some details are omitted, run with `RUST_BACKTRACE=full` for a verbose backtrace.
```

Will have to edit the daemonset and add a command line

```bash
kubectl edit daemonset mayastor-io-engine -n mayastor

# section to edit
command:
        - io-engine
        - --env-context=--iova-mode=pa # Add this line

```

Then delete the pods so they can be restarted:

```bash
kubectl delete pods -n mayastor -l app=io-engine
kubectl get pods -l app=io-engine

```

TODO fix the rest

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

### Bootstrap Argo CD:

```bash
kubectl apply -n argocd -f openebs-gitops/root-app-of-apps.yaml
```

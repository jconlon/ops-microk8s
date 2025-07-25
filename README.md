# ops-microk8s

Project to create a microk8s cluster with 5 nodes.

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

Building the kubernetes cluster consists of the following steps:

1. Install node hardware/machines/os.
1. Install Microk8s on each node.
1. Create the cluster by joining nodes to a master node.
1. Add initial set of services to the cluster with Microk8s addons.

## Addons

Will not use the openebs, mayastor or prometheus addons, but will install these with argocd and helm.

```bash
 microk8s enable dns

# Pihole is reserving range  192.168.0.100-192.168.0.150
# Use 192.168.0.200-192.168.0.220 for load balancer
 microk8s enable metallb:192.168.0.200-192.168.0.220

```

## ArgoCD

```bash
# Experiment with Helm first to get the correct values file
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace

# After reaching the UI the first time you can login with username: admin and the random password generated during the installation. You can find the password by running:

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Self manage argocd via helm values
kubectl apply -f argoCD-apps/argocd-self-managed.yaml
```

## OpenEBS

### Project status

[OpenEBS roadmap](https://github.com/openebs/openebs/blob/main/ROADMAP.md)

[Deprecated Projects](https://github.com/openebs/openebs/issues/3709)

Focus on these engines and release +4.2

Moving forward, the new OpenEBS product architecture and Roadmap centers round 2 core storage services. ‘Local’ and ‘Replicated’. These include the following Data Engines:

1. LocalPV-HostPath
2. LocalPV-LVM
3. LocalPV-ZFS
4. Mayastor

### Helm install

```bash


➜ helm upgrade --install openebs openebs/openebs \
  --namespace openebs \
  --values openebs-gitops/helm/openebs-mayastor-values.yaml \
  --create-namespace \
  --timeout 15m
Release "openebs" has been upgraded. Happy Helming!
NAME: openebs
LAST DEPLOYED: Thu Jul 10 13:57:10 2025
NAMESPACE: openebs
STATUS: deployed
REVISION: 2
NOTES:
Successfully installed OpenEBS.

Check the status by running: kubectl get pods -n openebs

The default values will install both Local PV and Replicated PV. However,
the Replicated PV will require additional configuration to be fuctional.
The Local PV offers non-replicated local storage using 3 different storage
backends i.e Hostpath, LVM and ZFS, while the Replicated PV provides one replicated highly-available
storage backend i.e Mayastor.

For more information,
- view the online documentation at https://openebs.io/docs
- connect with an active community on our Kubernetes slack channel.
        - Sign up to Kubernetes slack: https://slack.k8s.io
        - #openebs channel: https://kubernetes.slack.com/messages/openebs

```

### Label nodes

Label all the nodes to use mayastor as these all have a 4TB external drive to use for the diskpools.

```bash

kubectl label node whale openebs.io/engine=mayastor
kubectl label node tuna openebs.io/engine=mayastor
kubectl label node trout openebs.io/engine=mayastor
kubectl label node shamu openebs.io/engine=mayastor
kubectl label node mullet openebs.io/engine=mayastor

kubectl get pods -l app=io-engine -w
```

### Diskpools

```bash
k apply -f openebs-gitops/diskpools/tuna-pool.yaml

k apply -f openebs-gitops/diskpools/trout-pool.yaml

k apply -f openebs-gitops/diskpools/shamu-pool.yaml

k apply -f openebs-gitops/diskpools/mullet-pool.yaml

k apply -f openebs-gitops/diskpools/whale-pool.yaml

```

### Storage classes

`k apply -f openebs-gitops/storageclasses/mayastor-storage-classes.yaml `

### Problems

#### Mounting problems

Will have problems mounting if:

Setup instructions from the openebs docs. These have been incorporated in the `openebs-gitops/helm/openebs-mayastor-values.yaml` file.

If you are utilizing a custom Kubelet location or a Kubernetes distribution that uses a custom Kubelet location, it is necessary to modify the Kubelet directory in the Helm values at installation time. This can be accomplished by using the --set flag option in the Helm install command, as follows:

For Local PV LVM
--set lvm-localpv.lvmNode.kubeletDir=<your-directory-path>
For Local PV ZFS
--set zfs-localpv.zfsNode.kubeletDir=<your-directory-path>
For Replicated PV Mayastor
--set mayastor.csi.node.kubeletDir=<your-directory-path>
Specifically:

For MicroK8s, the Kubelet directory must be updated to /var/snap/microk8s/common/var/lib/kubelet/ by replacing the default /var/lib/kubelet/ with /var/snap/microk8s/common/var/lib/kubelet/.

```bash

Events:
  Type     Reason       Age              From               Message
  ----     ------       ----             ----               -------
  Normal   Scheduled    7s               default-scheduler  Successfully assigned monitoring/prometheus-prometheus-stack-kube-prom-prometheus-0 to whale
  Warning  FailedMount  3s (x4 over 7s)  kubelet            MountVolume.SetUp failed for volume "pvc-b2a1f151-b1a5-4c01-b7fa-158eb976fb61" : rpc error: code = Internal desc =

  Failed to find parent dir for mountpoint

   /var/snap/microk8s/common/var/lib/kubelet/pods/19c34319-4773-462a-974e-7ced70545acb/volumes/kubernetes.io~csi/pvc-b2a1f151-b1a5-4c01-b7fa-158eb976fb61/mount, volume b2a1f151-b1a5-4c01-b7fa-158eb976fb61


```

#### IOVA

This problem will show up in pods failing to initialize.

These fixes have been incorporated in the `openebs-gitops/helm/openebs-mayastor-values.yaml` file.

```bash
➜ kubectl logs openebs-io-engine-9fpxh -n openebs -c io-engine
[2025-07-10T18:09:47.420159992+00:00  INFO io_engine:io-engine.rs:271] Engine responsible for managing I/Os version 1.0.0, revision 6a266fd75f67 (v2.9.1+0)
[2025-07-10T18:09:47.420281917+00:00  INFO io_engine:io-engine.rs:240] free_pages 2MB: 1024 nr_pages 2MB: 1024
[2025-07-10T18:09:47.420288775+00:00  INFO io_engine:io-engine.rs:241] free_pages 1GB: 0 nr_pages 1GB: 0
[2025-07-10T18:09:47.420382014+00:00  INFO io_engine:io-engine.rs:302] kernel io_uring support: yes
[2025-07-10T18:09:47.420386670+00:00  INFO io_engine:io-engine.rs:306] kernel nvme initiator multipath support: yes
[2025-07-10T18:09:47.420411974+00:00  INFO io_engine::core::env:env.rs:951] loading mayastor config YAML file /var/local/openebs/io-engine/config.yaml
[2025-07-10T18:09:47.420429273+00:00  INFO io_engine::subsys::config:mod.rs:182] Config file /var/local/openebs/io-engine/config.yaml is empty, reverting to default config
[2025-07-10T18:09:47.420436992+00:00  INFO io_engine::subsys::config::opts:opts.rs:201] Overriding NVMF_TCP_MAX_QUEUE_DEPTH value to '32'
[2025-07-10T18:09:47.420441511+00:00  INFO io_engine::subsys::config::opts:opts.rs:201] Overriding NVMF_TCP_MAX_QPAIRS_PER_CTRL value to '32'
[2025-07-10T18:09:47.420446963+00:00  INFO io_engine::subsys::config::opts:opts.rs:201] Overriding NVMF_TCP_MAX_QUEUE_DEPTH value to '32'
[2025-07-10T18:09:47.420449816+00:00  INFO io_engine::subsys::config::opts:opts.rs:201] Overriding NVMF_TCP_MAX_QPAIRS_PER_CTRL value to '32'
[2025-07-10T18:09:47.420457920+00:00  INFO io_engine::subsys::config::opts:opts.rs:267] Overriding NVME_TIMEOUT value to '110s'
[2025-07-10T18:09:47.420462329+00:00  INFO io_engine::subsys::config::opts:opts.rs:267] Overriding NVME_TIMEOUT_ADMIN value to '30s'
[2025-07-10T18:09:47.420465837+00:00  INFO io_engine::subsys::config::opts:opts.rs:267] Overriding NVME_KATO value to '10s'
[2025-07-10T18:09:47.420486615+00:00  INFO io_engine::subsys::config:mod.rs:233] Applying Mayastor configuration settings
[2025-07-10T18:09:47.420492955+00:00  INFO io_engine::subsys::config::opts:opts.rs:395] NVMe Bdev options successfully applied
[2025-07-10T18:09:47.420496319+00:00  INFO io_engine::subsys::config::opts:opts.rs:538] Bdev options successfully applied
[2025-07-10T18:09:47.420500822+00:00  INFO io_engine::subsys::config::opts:opts.rs:694] Socket options successfully applied
[2025-07-10T18:09:47.420503762+00:00  INFO io_engine::subsys::config::opts:opts.rs:733] I/O buffer options successfully applied
[2025-07-10T18:09:47.420506666+00:00  INFO io_engine::subsys::config:mod.rs:239] Config {
    source: Some(
        "/var/local/openebs/io-engine/config.yaml",
    ),
    nvmf_tgt_conf: NvmfTgtConfig {
        name: "mayastor_target",
        max_namespaces: 2048,
        crdt: [
            30,
            0,
            0,
        ],
        opts_tcp: NvmfTransportOpts {
            max_queue_depth: 32,
            max_qpairs_per_ctrl: 32,
            in_capsule_data_size: 4096,
            max_io_size: 131072,
            io_unit_size: 131072,
            max_aq_depth: 32,
            num_shared_buf: 2047,
            buf_cache_size: 64,
            dif_insert_or_strip: false,
            abort_timeout_sec: 1,
            acceptor_poll_rate: 10000,
            zcopy: true,
            ack_timeout: 0,
            data_wr_pool_size: 0,
        },
        interface: None,
        rdma: None,
        opts_rdma: NvmfTransportOpts {
            max_queue_depth: 32,
            max_qpairs_per_ctrl: 32,
            in_capsule_data_size: 4096,
            max_io_size: 131072,
            io_unit_size: 8192,
            max_aq_depth: 32,
            num_shared_buf: 2047,
            buf_cache_size: 64,
            dif_insert_or_strip: false,
            abort_timeout_sec: 1,
            acceptor_poll_rate: 10000,
            zcopy: true,
            ack_timeout: 0,
            data_wr_pool_size: 4095,
        },
    },
    nvme_bdev_opts: NvmeBdevOpts {
        action_on_timeout: 4,
        timeout_us: 110000000,
        timeout_admin_us: 30000000,
        keep_alive_timeout_ms: 10000,
        transport_retry_count: 0,
        arbitration_burst: 0,
        low_priority_weight: 0,
        medium_priority_weight: 0,
        high_priority_weight: 0,
        nvme_adminq_poll_period_us: 1000,
        nvme_ioq_poll_period_us: 0,
        io_queue_requests: 0,
        delay_cmd_submit: true,
        bdev_retry_count: 0,
        transport_ack_timeout: 0,
        ctrlr_loss_timeout_sec: 0,
        reconnect_delay_sec: 0,
        fast_io_fail_timeout_sec: 0,
        disable_auto_failback: false,
        generate_uuids: true,
    },
    bdev_opts: BdevOpts {
        bdev_io_pool_size: 65535,
        bdev_io_cache_size: 512,
        iobuf_small_cache_size: 128,
        iobuf_large_cache_size: 16,
    },
    nexus_opts: NexusOpts {
        nvmf_enable: true,
        nvmf_discovery_enable: true,
        nvmf_nexus_port: 4421,
        nvmf_replica_port: 8420,
    },
    socket_opts: PosixSocketOpts {
        recv_buf_size: 2097152,
        send_buf_size: 2097152,
        enable_recv_pipe: true,
        enable_zero_copy_send: true,
        enable_quickack: true,
        enable_placement_id: 0,
        enable_zerocopy_send_server: true,
        enable_zerocopy_send_client: false,
        zerocopy_threshold: 0,
    },
    iobuf_opts: IoBufOpts {
        small_pool_count: 8192,
        large_pool_count: 2048,
        small_bufsize: 8192,
        large_bufsize: 135168,
    },
    eal_opts: EalOpts {
        reactor_mask: None,
        core_list: None,
        developer_delay: None,
    },
}
[2025-07-10T18:09:47.425497173+00:00  INFO async_nats:lib.rs:996] event: connected
EAL: alloc_pages_on_heap(): couldn't allocate memory due to IOVA exceeding limits of current DMA mask
EAL: alloc_pages_on_heap(): Please try initializing EAL with --iova-mode=pa parameter
EAL: error allocating rte services array
EAL: FATAL: rte_service_init() failed
EAL: rte_service_init() failed
thread 'main' panicked at io-engine/src/core/env.rs:790:13:
Failed to init EAL
stack backtrace:
   0: std::panicking::begin_panic
   1: io_engine::core::env::MayastorEnvironment::init
   2: io_engine::main
note: Some details are omitted, run with `RUST_BACKTRACE=full` for a verbose backtrace.

```

### microk8s addon

Abandoned this in favor of helm install (See above.) as this add on is a very old version and I had problems creating diskpools for mayastor on tuna node.

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

#### Problems

Similar problems with helm..

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

On each Ubuntu node these configurations are necessary prior to installing openebs and mayastor.

```bash
# HugePages

sudo sysctl vm.nr_hugepages=1024
echo 'vm.nr_hugepages=1024' | sudo tee -a /etc/sysctl.conf

# NVMe modules
sudo modprobe nvme_tcp
echo 'nvme-tcp' | sudo tee -a /etc/modules-load.d/microk8s.conf
```

## Monitoring

```bash
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring/helm/prometheus-values.yaml \
  --create-namespace \
  --timeout 15m

Release "prometheus-stack" does not exist. Installing it now.
NAME: prometheus-stack
LAST DEPLOYED: Fri Jul 11 19:50:24 2025
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
NOTES:
kube-prometheus-stack has been installed. Check its status by running:
  kubectl --namespace monitoring get pods -l "release=prometheus-stack"

Get Grafana 'admin' user password by running:

  kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo

Access Grafana local instance:

  export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=prometheus-stack" -oname)
  kubectl --namespace monitoring port-forward $POD_NAME 3000

Visit https://github.com/prometheus-operator/kube-prometheus for instructions on how to create & configure Alertmanager and Prometheus instances using the Operator.


☸ microk8s (openebs) in ops-microk8s [!?] took 24s
➜   kubectl --namespace monitoring get secrets prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo
openebs-admin-secure-password



```

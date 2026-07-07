# MicroK8s Cluster Maintenance Guide

This document provides procedures for gracefully shutting down and restarting the MicroK8s cluster for preventative maintenance.

## Cluster Overview

- **Platform**: MicroK8s v1.32.3 on Ubuntu
- **Nodes**: 8 nodes total
  - Control plane nodes: mullet, trout, whale
  - Worker nodes: tuna, gold, squid, puffer, carp
- **Storage**:
  - Rook/Ceph distributed storage with 3-way replication across Dell R320 nodes (gold, squid, puffer, carp)
- **Key Applications**:
  - PostgreSQL cluster (production-postgresql) - 3 instances with S3 backups
  - Monitoring stack (Prometheus, Grafana, AlertManager)
  - ArgoCD (GitOps management)

## Pre-Shutdown Checklist

Before initiating maintenance, verify the cluster is in a healthy state:

### 1. Check Overall Cluster Health

```bash
# Check all nodes are Ready
kubectl get nodes

# Check for any failing pods
kubectl get pods --all-namespaces | grep -v "Running\|Completed"

# Check ArgoCD application status
devbox run -- argocd app list
```

**Expected Output**: All nodes should be `Ready`, all critical pods `Running`, ArgoCD apps `Healthy` and `Synced`.

### 2. Verify PostgreSQL Cluster Status

```bash
# Check PostgreSQL cluster health
kubectl get cluster production-postgresql -n postgresql-system

# Verify all instances are ready
kubectl get pods -n postgresql-system -l cnpg.io/cluster=production-postgresql

# Check current primary instance
kubectl get cluster production-postgresql -n postgresql-system -o jsonpath='{.status.currentPrimary}'

# Verify continuous archiving is working
kubectl get cluster production-postgresql -n postgresql-system -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'
```

**Expected Output**:
- Cluster phase: `Cluster in healthy state`
- All 3 pods should be `Running`
- Continuous archiving status: `"status": "True"`

### 3. Trigger On-Demand PostgreSQL Backup

```bash
# Create an immediate backup before maintenance
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: pre-maintenance-backup-$(date +%Y%m%d%H%M%S)
  namespace: postgresql-system
spec:
  method: barmanObjectStore
  cluster:
    name: production-postgresql
EOF

# Wait for backup to complete (check status)
kubectl get backups -n postgresql-system

# Once complete, verify backup succeeded
kubectl describe backup <backup-name> -n postgresql-system | grep Phase
```

**Expected Output**: Backup phase should be `completed`.

### 4. Check Rook/Ceph Storage

```bash
# Check Ceph cluster health
kubectl get cephcluster -n rook-ceph

# Check Ceph status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Check Ceph OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status

# Verify storage health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail
```

**Expected Output**:
- Ceph cluster: `Ready`
- Ceph health: `HEALTH_OK`
- All OSDs: `up` and `in`

### 5. Check Monitoring Stack

```bash
# Check Prometheus stack pods
kubectl get pods -n monitoring

# Verify Prometheus is healthy
kubectl get prometheus -n monitoring
```

**Expected Output**: All pods should be `Running`.

### 6. Document Current State

```bash
# Save cluster state for reference
kubectl get nodes -o wide > pre-maintenance-nodes.txt
kubectl get pods --all-namespaces > pre-maintenance-pods.txt
kubectl get pv,pvc --all-namespaces > pre-maintenance-storage.txt
kubectl get cephcluster -n rook-ceph > pre-maintenance-ceph.txt
```

---

## Graceful Shutdown Procedure

Follow these steps in order to safely shut down the cluster:

### Phase 1: Application Shutdown

#### 1.1 Gracefully Stop Kafka (REQUIRED — do NOT skip)

> **Critical**: Kafka uses KRaft (Raft-based metadata consensus). If Kafka brokers are killed abruptly (SIGKILL via node reboot), the KRaft metadata log is left in an inconsistent mid-write state. Recovery requires deleting all broker PVCs and restarting from scratch (all topic data lost).

```bash
# Gracefully delete Kafka broker pods — sends SIGTERM so brokers flush and checkpoint cleanly
# Do NOT use --force --grace-period=0 here
kubectl delete pod kafka-kafka-0 kafka-kafka-1 kafka-kafka-2 -n kafka-system

# Wait for pods to terminate (Strimzi will not recreate them while reconciliation is paused)
kubectl annotate kafka kafka -n kafka-system strimzi.io/pause-reconciliation=true
kubectl annotate strimzipodset kafka-kafka -n kafka-system strimzi.io/pause-reconciliation=true
kubectl wait --for=delete pod/kafka-kafka-0 pod/kafka-kafka-1 pod/kafka-kafka-2 -n kafka-system --timeout=120s

# Verify brokers are stopped
kubectl get pods -n kafka-system -l strimzi.io/name=kafka-kafka
```

**Expected Output**: No kafka-kafka-* pods.

#### 1.2 Scale Down Non-Critical Workloads (Optional)

```bash
# Pause ArgoCD auto-sync to prevent reconciliation during maintenance
devbox run -- argocd app set <app-name> --sync-policy none

# Or suspend ArgoCD applications
kubectl patch application <app-name> -n argocd -p '{"spec":{"syncPolicy":null}}'
```

#### 1.3 Cordon All Nodes

Prevent new pods from being scheduled:

```bash
# Cordon all nodes
kubectl cordon mullet
kubectl cordon trout
kubectl cordon tuna
kubectl cordon whale
kubectl cordon gold
kubectl cordon squid
kubectl cordon puffer
kubectl cordon carp

# Verify all nodes are cordoned
kubectl get nodes
```

**Expected Output**: All nodes should show `SchedulingDisabled`.

### Phase 2: Storage Preparation

#### 2.1 Verify Ceph Cluster Health

```bash
# Check Ceph cluster health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Check for any ongoing recovery or rebalancing
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail

# Verify OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status

# Check placement group status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat
```

**Expected Output**: Health `HEALTH_OK`, no active recovery, all OSDs `up` and `in`.

#### 2.2 Scale Down PostgreSQL Replicas (Optional for Complete Shutdown)

```bash
# For complete cluster shutdown, scale PostgreSQL to 1 instance
# This reduces the number of storage volumes to detach
kubectl patch cluster production-postgresql -n postgresql-system \
  --type merge \
  -p '{"spec":{"instances":1}}'

# Wait for scale-down to complete
kubectl get pods -n postgresql-system -w
```

**Note**: Skip this step if you want all PostgreSQL instances to remain available during the node-by-node shutdown process.

### Phase 3: Node Shutdown Sequence

Drain and shutdown nodes one at a time, starting with worker nodes:

> **Note**: SSH keys are not available in Claude Code sessions. When Claude guides a shutdown, it will copy each `ssh <node> sudo shutdown -h now` command to the clipboard via `xclip` for you to paste and run in your terminal.

#### 3.1 Drain Worker Nodes First

Drain Dell R320 nodes first (Rook/Ceph migration nodes):

```bash
# Drain gold (Dell R320)
kubectl drain gold --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep gold
ssh gold
sudo shutdown -h now
exit

# Wait 2-3 minutes, then drain squid
kubectl drain squid --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep squid
ssh squid
sudo shutdown -h now
exit

# Wait 2-3 minutes, then drain puffer
kubectl drain puffer --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep puffer
ssh puffer
sudo shutdown -h now
exit

# Wait 2-3 minutes, then drain carp
kubectl drain carp --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep carp
ssh carp
sudo shutdown -h now
exit
```

Then drain remaining worker node:

```bash
# Drain tuna (worker node)
kubectl drain tuna --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep tuna
ssh tuna
sudo shutdown -h now
exit
```

#### 3.2 Drain and Shutdown Non-Primary Control Plane Nodes

```bash
# Identify which control plane node is NOT the current PostgreSQL primary
kubectl get cluster production-postgresql -n postgresql-system -o jsonpath='{.status.currentPrimary}'

# Drain mullet (if not primary)
kubectl drain mullet --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep mullet
ssh mullet
sudo shutdown -h now
exit

# Wait 2-3 minutes, then drain trout (if not primary)
kubectl drain trout --ignore-daemonsets --delete-emptydir-data --force --grace-period=300
kubectl get pods --all-namespaces -o wide | grep trout
ssh trout
sudo shutdown -h now
exit
```

#### 3.3 Shutdown Final Control Plane Node (Primary Host)

```bash
# This should be the node hosting the PostgreSQL primary
# Drain whale (or whichever node is last)
kubectl drain whale --ignore-daemonsets --delete-emptydir-data --force --grace-period=300

# Give PostgreSQL time to archive WALs (wait for stopDelay: 1800s = 30 minutes default)
# Monitor PostgreSQL shutdown
kubectl logs -n postgresql-system production-postgresql-<primary-number> -f

# Once PostgreSQL has shut down gracefully, shutdown the node
ssh whale
sudo shutdown -h now
exit
```

#### 3.4 Shutdown Remaining Nodes

If you're running kubectl from your local machine, the cluster will be completely down at this point. If you need to shutdown any remaining nodes:

```bash
# SSH to each remaining node and shutdown
ssh <node-name>
sudo shutdown -h now
exit
```

---

## Startup Procedure

Power on nodes in reverse order of shutdown:

### Phase 1: Start Control Plane Nodes

#### 1.1 Power On Primary Control Plane Nodes

```bash
# Power on whale (or the last node shutdown)
# Power on trout
# Power on mullet

# Wait 2-3 minutes for nodes to boot
```

#### 1.2 Verify Control Plane Health

```bash
# Wait for nodes to appear
kubectl get nodes

# Wait for all nodes to become Ready (may take 5-10 minutes)
kubectl get nodes -w

# Check system pods are running
kubectl get pods -n kube-system
```

**Expected Output**: All control plane nodes should be `Ready`.

### Phase 2: Start Worker Nodes

```bash
# Power on tuna (worker node)
# Wait for tuna to become Ready
kubectl get nodes -w

# Power on Dell R320 nodes (Ceph storage nodes)
# Power on gold
# Power on squid
# Power on puffer
# Power on carp

# Wait for all nodes to become Ready
kubectl get nodes -w
```

### Phase 3: Uncordon All Nodes

```bash
# Uncordon all nodes to allow scheduling
kubectl uncordon mullet
kubectl uncordon trout
kubectl uncordon tuna
kubectl uncordon whale
kubectl uncordon gold
kubectl uncordon squid
kubectl uncordon puffer
kubectl uncordon carp

# Verify all nodes are ready and schedulable
kubectl get nodes
```

**Expected Output**: All nodes should be `Ready` with `<none>` in the `STATUS` column (no `SchedulingDisabled`).

### Phase 4: Verify Storage Recovery

#### 4.1 Check Rook/Ceph Status

```bash
# Wait for Ceph pods to start (may take 2-5 minutes)
kubectl get pods -n rook-ceph

# Check Ceph cluster status
kubectl get cephcluster -n rook-ceph

# Verify Ceph health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Check OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status
```

**Expected Output**: Ceph cluster `Ready`, health `HEALTH_OK`, all OSDs `up` and `in`.

#### 4.2 Verify Storage Health

```bash
# Check for any recovery or rebalancing
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail

# Check placement group status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat

# If any placement groups are recovering, monitor progress
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -w
```

### Phase 5: Verify Application Recovery

#### 5.1 Check PostgreSQL Cluster

```bash
# Wait for PostgreSQL pods to start (may take 3-5 minutes)
kubectl get pods -n postgresql-system

# Check cluster status
kubectl get cluster production-postgresql -n postgresql-system

# Verify primary is elected
kubectl get cluster production-postgresql -n postgresql-system -o jsonpath='{.status.currentPrimary}'

# Check all instances are ready
kubectl get pods -n postgresql-system -l cnpg.io/cluster=production-postgresql

# Verify continuous archiving is working
kubectl get cluster production-postgresql -n postgresql-system -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")]}'

# If you scaled down to 1 instance, scale back up
kubectl patch cluster production-postgresql -n postgresql-system \
  --type merge \
  -p '{"spec":{"instances":3}}'
```

**Expected Output**:
- Cluster status: `Cluster in healthy state`
- All pods: `Running`
- Continuous archiving: `"status": "True"`

#### 5.2 Resume Kafka (if stopped before shutdown)

```bash
# Resume Strimzi reconciliation (paused during shutdown)
kubectl annotate kafka kafka -n kafka-system strimzi.io/pause-reconciliation-
kubectl annotate strimzipodset kafka-kafka -n kafka-system strimzi.io/pause-reconciliation-

# Wait for all 3 brokers to reach Ready
kubectl wait --for=condition=Ready pod/kafka-kafka-0 pod/kafka-kafka-1 pod/kafka-kafka-2 -n kafka-system --timeout=300s

# Verify cluster is healthy
kubectl get pods -n kafka-system
```

**Expected Output**: All 3 kafka-kafka-* pods `1/1 Running`. Downstream services (kafka-entity-operator, kafka-connect, schema-registry, argo-events) self-recover within 2-5 minutes.

> **Note**: If Kafka brokers fail to form quorum (CrashLoopBackOff due to KRaft metadata corruption from an unclean shutdown), all topic data must be treated as lost. See the full recovery procedure in the [Kafka KRaft Metadata Corruption](#kafka-kraft-metadata-corruption) troubleshooting section — **PV cleanup is required** in addition to PVC deletion.

#### 5.3 Verify Database Connectivity

```bash
# Get the cluster connection details
kubectl get service production-postgresql-rw -n postgresql-system

# Test connection from a pod
kubectl run -it --rm psql-test --image=postgres:17 --restart=Never -- \
  psql -h production-postgresql-rw.postgresql-system.svc.cluster.local -U app -d app -c "SELECT version();"
```

**Expected Output**: Connection successful, version information displayed.

#### 5.4 Check Monitoring Stack

```bash
# Check Prometheus pods
kubectl get pods -n monitoring

# Verify Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:80 &
# Open http://localhost:9090/targets in browser

# Check Grafana
kubectl port-forward -n monitoring svc/grafana 3000:80 &
# Open http://localhost:3000 in browser
```

#### 5.5 Check ArgoCD

```bash
# Login to ArgoCD
devbox run -- argocd-login

# Check all applications
devbox run -- argocd app list

# If any applications are out of sync, sync them
devbox run -- argocd app sync <app-name>

# Re-enable auto-sync if disabled
devbox run -- argocd app set <app-name> --sync-policy automated
```

### Phase 6: Final Verification

```bash
# Check all pods are running
kubectl get pods --all-namespaces | grep -v "Running\|Completed"

# Check PV/PVC status
kubectl get pv,pvc --all-namespaces

# Compare with pre-maintenance state
diff pre-maintenance-pods.txt <(kubectl get pods --all-namespaces)
diff pre-maintenance-storage.txt <(kubectl get pv,pvc --all-namespaces)
```

---

## Troubleshooting

### PostgreSQL Issues

#### PostgreSQL Primary Not Elected

```bash
# Check cluster status
kubectl describe cluster production-postgresql -n postgresql-system

# Check pod events
kubectl describe pod production-postgresql-1 -n postgresql-system

# If needed, trigger a manual failover
kubectl cnpg promote production-postgresql-1 -n postgresql-system
```

#### PostgreSQL Pods in CrashLoopBackOff

```bash
# Check pod logs
kubectl logs production-postgresql-1 -n postgresql-system

# Common issues:
# 1. Storage I/O errors - check Ceph health
# 2. WAL archiving failures - check S3 credentials
# 3. Recovery failures - may need to restore from backup

# Check storage status
kubectl get cephcluster -n rook-ceph
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status

# Restart pod if needed
kubectl delete pod production-postgresql-1 -n postgresql-system
```

### Rook/Ceph Storage Issues

#### Ceph Cluster Not Healthy

```bash
# Check Ceph cluster status
kubectl get cephcluster -n rook-ceph

# Check detailed health
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail

# Check Ceph pods
kubectl get pods -n rook-ceph

# Check OSD status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd status

# Restart Ceph operator if needed
kubectl rollout restart deployment rook-ceph-operator -n rook-ceph
```

#### OSD Pods Not Starting

```bash
# Check OSD pods
kubectl get pods -n rook-ceph -l app=rook-ceph-osd

# Check OSD logs
kubectl logs -n rook-ceph -l app=rook-ceph-osd --tail=100

# Common causes:
# 1. Node not ready
# 2. Disk not available or has issues
# 3. Network connectivity issues

# Check node status
kubectl get nodes
kubectl describe node <node-name>

# If OSD won't start, restart the pod
kubectl delete pod -n rook-ceph <osd-pod-name>
```

#### Placement Groups Degraded

```bash
# Check placement group status
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg stat

# Check which PGs are degraded
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph pg dump | grep -E 'degraded|undersized|peering'

# PGs should automatically recover
# Monitor recovery progress
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph -w

# If recovery doesn't start automatically, check:
# 1. All OSDs are up and in
# 2. Network connectivity between Ceph nodes
# 3. Sufficient storage capacity
```

#### Volume Mount Failures

```bash
# Check Ceph CSI pods
kubectl get pods -n rook-ceph -l app=csi-rbdplugin

# Check CSI driver logs
kubectl logs -n rook-ceph -l app=csi-rbdplugin --tail=100

# Common causes:
# 1. Ceph cluster not healthy
# 2. Network connectivity issues
# 3. RBD image mapped incorrectly

# Restart pod using the volume if needed
kubectl delete pod <pod-name> -n <namespace>
```

### Node Issues

#### Node NotReady After Boot

```bash
# Check node status
kubectl describe node <node-name>

# Common issues:
# 1. Kubelet not started
# 2. CNI issues
# 3. Disk pressure

# SSH to node and check services
ssh <node-name>
sudo microk8s status
sudo systemctl status snap.microk8s.daemon-kubelite

# Restart MicroK8s if needed
sudo microk8s stop
sudo microk8s start

# Check kubelet logs
sudo journalctl -u snap.microk8s.daemon-kubelite -n 100
```

#### Pods Stuck in Terminating

```bash
# Check for finalizers
kubectl get pod <pod-name> -n <namespace> -o yaml | grep -A 5 finalizers

# Force delete if necessary (use with caution)
kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0

# If still stuck, remove finalizers
kubectl patch pod <pod-name> -n <namespace> -p '{"metadata":{"finalizers":[]}}' --type=merge
```

### ArgoCD Issues

#### Applications Out of Sync After Restart

```bash
# Refresh applications
devbox run -- argocd app get <app-name> --refresh

# Force sync if needed
devbox run -- argocd app sync <app-name> --force

# Check sync errors
devbox run -- argocd app get <app-name>
```

#### ArgoCD API Server Not Responding

```bash
# Check ArgoCD pods
kubectl get pods -n argocd

# Restart ArgoCD server if needed
kubectl rollout restart deployment argocd-server -n argocd

# Check logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

### Kafka KRaft Metadata Corruption

**Symptom**: All 3 Kafka broker pods in CrashLoopBackOff after a node restart. Logs show `OffsetOutOfRangeException` or brokers stuck in election livelock (`voteStates={0=GRANTED, 1=UNRECORDED, 2=UNRECORDED}`) with no leader forming.

**Root cause**: Kafka brokers received SIGKILL (not SIGTERM) during node shutdown, leaving the KRaft metadata log (`__cluster_metadata-0`) in an inconsistent mid-write state.

**Recovery** (all Kafka topic data is lost — treat as disposable):

```bash
# 1. Pause Strimzi to prevent interference
kubectl annotate kafka kafka -n kafka-system strimzi.io/pause-reconciliation=true
kubectl annotate strimzipodset kafka-kafka -n kafka-system strimzi.io/pause-reconciliation=true

# 2. Force-delete broker pods and all 3 data PVCs
kubectl delete pod kafka-kafka-0 kafka-kafka-1 kafka-kafka-2 -n kafka-system --force --grace-period=0
kubectl delete pvc data-0-kafka-kafka-0 data-0-kafka-kafka-1 data-0-kafka-kafka-2 -n kafka-system

# 2a. Remove pvc-protection finalizers if PVCs are stuck Terminating
for pvc in $(kubectl get pvc -n kafka-system -o name 2>/dev/null); do
  kubectl patch $pvc -n kafka-system -p '{"metadata":{"finalizers":[]}}' --type=merge
done

# 2b. REQUIRED: delete all Released PVs for Kafka — rook-ceph-block uses reclaimPolicy: Retain,
# so deleted PVCs leave orphaned Released PVs. New PVCs cannot bind (WaitForFirstConsumer
# deadlock) until these are removed. Run after every PVC wipe.
kubectl get pv | grep kafka-system
kubectl delete pv $(kubectl get pv --no-headers | grep kafka-system | awk '{print $1}')

# 3. Resume Strimzi reconciliation — Strimzi provisions fresh empty PVCs and restarts brokers
kubectl annotate strimzipodset kafka-kafka -n kafka-system strimzi.io/pause-reconciliation-
kubectl annotate kafka kafka -n kafka-system strimzi.io/pause-reconciliation-

# 4. Monitor recovery (expect 2 restart cycles before all 3 reach 1/1 Ready, ~3-5 minutes)
kubectl get pods -n kafka-system -l strimzi.io/name=kafka-kafka -w
```

**Expected recovery time**: 3-5 minutes after step 3.

> **Warning**: Skipping step 2b causes new PVCs to enter a `WaitForFirstConsumer` deadlock where the CSI provisioner cannot bind new PVCs because stale Released PVs with the same RBD image IDs are still registered. Multiple recovery rounds compound the problem (9 orphaned PVs observed in practice). Always check `kubectl get pv | grep kafka-system` before resuming Strimzi.

**Prevention**: Always run Section 1.1 (Gracefully Stop Kafka) before any node shutdown.

### Kafka Connect Internal Topics — cleanup.policy=delete

**Symptom**: After a full Kafka PVC/PV wipe and recovery, `kafka-connect-connect-0` enters CrashLoopBackOff with:
```
ConfigException: Topic 'kafka-connect-cluster-offsets' supplied via the 'offset.storage.topic' property is required to have 'cleanup.policy=compact'... but found the topic currently has 'cleanup.policy=delete'.
```
Or the connector `atom-entries-s3-sink` shows `READY=False` with task error:
```
ConnectException: Failed to start task atom-entries-s3-sink-0 since it is not a recognizable type (source or sink)
```

**Root cause**: When Kafka's PVCs are wiped (during KRaft recovery), all internal topics are lost. Kafka Connect recreates them on startup but uses the Kafka broker default `cleanup.policy=delete` instead of the required `compact`. The `delete` policy can also corrupt task config records after many crash-loop restarts (records are deleted before compaction).

**Fix** — alter all three internal topics to `compact`, then let Connect restart:

```bash
# Alter all three Connect internal topics to compact policy
kubectl exec -n kafka-system kafka-kafka-0 -- /opt/kafka/bin/kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name kafka-connect-cluster-offsets \
  --alter --add-config 'cleanup.policy=compact'

kubectl exec -n kafka-system kafka-kafka-0 -- /opt/kafka/bin/kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name kafka-connect-cluster-configs \
  --alter --add-config 'cleanup.policy=compact'

kubectl exec -n kafka-system kafka-kafka-0 -- /opt/kafka/bin/kafka-configs.sh \
  --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name kafka-connect-cluster-status \
  --alter --add-config 'cleanup.policy=compact'

# Verify
kubectl exec -n kafka-system kafka-kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --describe \
  --topic kafka-connect-cluster-offsets
# Configs should include: cleanup.policy=compact

# Connect pods will self-restart and recover; wait for 1/1 Running
kubectl wait --for=condition=Ready pod/kafka-connect-connect-0 pod/kafka-connect-connect-1 \
  -n kafka-system --timeout=180s

# Verify connectors are Ready
kubectl get kafkaconnector -n kafka-system
```

> **Do NOT delete the internal topics** to fix this. Deleting them while Connect is running causes Connect to immediately recreate them with `delete` policy, creating a loop. Alter in-place instead.

**Expected recovery time**: ~2 minutes after altering topics.

### General Recovery Steps

#### If Cluster Fails to Come Up Cleanly

1. **Check Control Plane**:
   ```bash
   kubectl get nodes
   kubectl get pods -n kube-system
   ```

2. **Check Storage**:
   ```bash
   kubectl get cephcluster -n rook-ceph
   kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph status
   ```

3. **Check Critical Apps**:
   ```bash
   kubectl get pods -n postgresql-system
   kubectl get pods -n monitoring
   kubectl get pods -n argocd
   ```

4. **Review Logs**:
   ```bash
   # Check kubelet logs on each node
   ssh <node-name>
   sudo journalctl -u snap.microk8s.daemon-kubelite -f
   ```

5. **Restart Services Sequentially**:
   - Restart storage layer first (Rook/Ceph)
   - Then restart databases (PostgreSQL)
   - Finally restart applications

---

## Best Practices

1. **Always create a backup** before maintenance
2. **Schedule maintenance** during low-usage periods
3. **Document any changes** made during maintenance
4. **Test the procedure** in a non-production environment first
5. **Keep maintenance windows** to a reasonable duration (4-6 hours)
6. **Have a rollback plan** if issues occur
7. **Monitor continuously** during the restart process
8. **Verify data integrity** after restart (check PostgreSQL, verify backups)

---

## Timing Expectations

- **Node boot time**: 2-3 minutes per node
- **Kubernetes control plane ready**: 5-10 minutes after first node boots
- **Rook/Ceph ready**: 2-5 minutes after nodes are Ready
- **PostgreSQL cluster ready**: 3-5 minutes after storage is ready
- **Full cluster operational**: 15-30 minutes after power-on
- **Ceph recovery/rebalancing** (if needed): Varies based on data size and cluster load

**Total maintenance window estimate**: 1-2 hours for clean shutdown and restart.

---

## Emergency Contacts

- **Cluster Administrator**: jconlon
- **Backup Location**: S3 bucket `s3://postgresql-microk8s-one/postgresql-backups/production/`
- **Documentation**: `/home/jconlon/git/ops-microk8s/`

---

## Change Log

| Date | Changes | Performed By |
|------|---------|--------------|
| 2026-06-23 | **Post-recovery follow-up**: `just test` revealed `kafka-connect-healthy` failing — `kafka-connect-connect-0` in CrashLoopBackOff (43 restarts). Root cause: Kafka Connect internal topics (`kafka-connect-cluster-offsets`, `configs`, `status`) were recreated with `cleanup.policy=delete` after the June 23 Kafka PVC/PV wipe. Connect requires `compact` and refuses to start with `delete`. Also: `atom-entries-s3-sink` task 0 failed with "not a recognizable type (source or sink)" due to corrupted task config record from crash-loop cycling on the delete-policy topic. Fix: altered all three topics to `cleanup.policy=compact` via `kafka-configs.sh` on the broker; both Connect pods reached 1/1 Running, both connectors `READY=True`. **Do not delete internal topics to fix** — Connect immediately recreates them with delete policy. | jconlon / Claude Code |
| 2026-06-23 | Graceful cluster shutdown and restart due to lab A/C failure. Pre-shutdown: Ceph HEALTH_OK, PostgreSQL healthy (primary on mullet, 3/3 instances), continuous archiving active, on-demand backup triggered and completed. Kafka gracefully stopped first (SIGTERM + Strimzi reconciliation paused) — no KRaft corruption. Ceph `noout` set. All nodes drained and shut down via SSH (commands clipboard-copied — no SSH keys in session). PDB-blocked pods (Ceph mgr, PostgreSQL replicas, Prometheus, AlertManager) were force-deleted to unblock drains; all had Ceph storage already offline so no data risk. Mullet kept running (control plane + Claude Code host). **Restart**: All 8 nodes came up Ready. Ceph HEALTH_OK after `noout` cleared (~2 min recovery). PostgreSQL 3/3 healthy. **Kafka recovery required**: KRaft election livelock on fresh PVCs (`voteStates={0=GRANTED,1=REJECTED}`) — root cause: `reclaimPolicy: Retain` left orphaned Released PVs from multiple recovery rounds; new PVCs entered WaitForFirstConsumer deadlock with stale PVs. Fix: deleted all Kafka PVCs, force-removed `pvc-protection` finalizers, deleted all 9 orphaned Kafka PVs, then resumed Strimzi. Brokers formed clean quorum on fresh PVCs in ~1 min. **Lesson**: Add PV cleanup step to Kafka recovery procedure — Retain policy requires manual PV deletion after PVC wipe. | jconlon / Claude Code |
| 2026-06-16 | Cluster startup after 2026-06-13 shutdown. All 8 nodes came up; Ceph HEALTH_OK after `noout` cleared; PostgreSQL recovered (primary on mullet). **Kafka KRaft recovery required**: Kafka brokers were killed by SIGKILL during the June 13 shutdown (nodes rebooted without draining Kafka first). The KRaft metadata log was left in a corrupt mid-write state causing `OffsetOutOfRangeException` on all 3 brokers. All Kafka topic data was disposable; recovery: deleted all 3 broker PVCs and force-deleted broker pods, then resumed Strimzi reconciliation — brokers provisioned fresh PVCs and formed quorum cleanly. Total Kafka recovery time: ~3 hours of troubleshooting + 10 minutes to execute. **Root cause**: Kafka was not gracefully stopped before node shutdown. Added mandatory Kafka pre-shutdown step (Section 1.1) to prevent recurrence. | jconlon / Claude Code |
| 2026-06-13 | Graceful cluster shutdown — all nodes except mullet (trout, tuna, whale, gold, squid, puffer, carp). Pre-shutdown checks passed: Ceph HEALTH_OK, PostgreSQL healthy (primary on trout), continuous archiving active, last backup completed 25 min prior. Ceph `noout` flag set before shutdown. Nodes cordoned via kubectl then shut down via SSH (commands copied to clipboard — SSH keys not available in Claude session). K8s API became temporarily unresponsive after whale (control plane) was shut down without drain; expected behavior with dqlite HA when a member leaves abruptly. Trout (last non-mullet node) shut down directly without drain since API was unavailable. Mullet remained up throughout. **NOTE**: Kafka was NOT explicitly stopped before node shutdown — this caused KRaft metadata corruption requiring full recovery on 2026-06-16. | jconlon / Claude Code |
| 2025-11-03 | Initial document creation | Claude Code |

---

## References

- [MicroK8s Documentation](https://microk8s.io/docs)
- [Kubernetes Node Drain](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Rook/Ceph Documentation](https://rook.io/docs/rook/latest/)
- [Ceph Operations](https://docs.ceph.com/en/latest/rados/operations/)
- [CloudNativePG Kubernetes Upgrade](https://cloudnative-pg.io/documentation/current/kubernetes_upgrade/)
- [CloudNativePG Automated Failover](https://cloudnative-pg.io/documentation/current/failover/)

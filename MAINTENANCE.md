# MicroK8s Cluster Maintenance Guide

This document provides procedures for gracefully shutting down and restarting the MicroK8s cluster for preventative maintenance.

## Cluster Overview

- **Platform**: MicroK8s v1.32.3 on Ubuntu
- **Nodes**: 5 nodes total
  - Control plane nodes: mullet, trout, whale
  - Worker nodes: shamu, tuna
- **Storage**: OpenEBS Mayastor with external 4TB drives
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

### 4. Check OpenEBS Mayastor Storage

```bash
# Check diskpool status
kubectl get diskpools -n openebs

# Check Mayastor volumes
kubectl mayastor get volumes -n openebs

# Verify all volume replicas are healthy
kubectl mayastor get volume-replica-topologies -n openebs
```

**Expected Output**:
- All diskpools: `Online`
- All volumes: `Online`
- All replicas: `Online`

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
kubectl get diskpools -n openebs > pre-maintenance-diskpools.txt
```

---

## Graceful Shutdown Procedure

Follow these steps in order to safely shut down the cluster:

### Phase 1: Application Shutdown

#### 1.1 Scale Down Non-Critical Workloads (Optional)

```bash
# Pause ArgoCD auto-sync to prevent reconciliation during maintenance
devbox run -- argocd app set <app-name> --sync-policy none

# Or suspend ArgoCD applications
kubectl patch application <app-name> -n argocd -p '{"spec":{"syncPolicy":null}}'
```

#### 1.2 Cordon All Nodes

Prevent new pods from being scheduled:

```bash
# Cordon all nodes
kubectl cordon mullet
kubectl cordon shamu
kubectl cordon trout
kubectl cordon tuna
kubectl cordon whale

# Verify all nodes are cordoned
kubectl get nodes
```

**Expected Output**: All nodes should show `SchedulingDisabled`.

### Phase 2: Storage Preparation

#### 2.1 Verify No Active I/O Operations

```bash
# Check for any ongoing rebuild operations
kubectl mayastor get rebuild-history -n openebs

# Check volume replica status
kubectl mayastor get volume-replica-topologies -n openebs

# Ensure no volumes are degraded
kubectl mayastor get volumes -n openebs | grep -v "Online"
```

**Expected Output**: No active rebuilds, all replicas `Online`.

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

#### 3.1 Drain Worker Nodes First

```bash
# Drain shamu (worker node)
kubectl drain shamu --ignore-daemonsets --delete-emptydir-data --force --grace-period=300

# Wait for all pods to be evicted
kubectl get pods --all-namespaces -o wide | grep shamu

# SSH to shamu and shutdown
ssh shamu
sudo shutdown -h now
exit
```

Wait 2-3 minutes for node to fully shutdown, then repeat for next worker node:

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
# Power on tuna
# Power on shamu

# Wait for nodes to become Ready
kubectl get nodes -w
```

### Phase 3: Uncordon All Nodes

```bash
# Uncordon all nodes to allow scheduling
kubectl uncordon mullet
kubectl uncordon shamu
kubectl uncordon trout
kubectl uncordon tuna
kubectl uncordon whale

# Verify all nodes are ready and schedulable
kubectl get nodes
```

**Expected Output**: All nodes should be `Ready` with `<none>` in the `STATUS` column (no `SchedulingDisabled`).

### Phase 4: Verify Storage Recovery

#### 4.1 Check OpenEBS Mayastor Status

```bash
# Wait for Mayastor pods to start (may take 2-5 minutes)
kubectl get pods -n openebs | grep -E "mayastor|io-engine"

# Check diskpool status
kubectl get diskpools -n openebs

# Verify all diskpools are Online
kubectl mayastor get pools -n openebs
```

**Expected Output**: All diskpools should be `Online`.

#### 4.2 Verify Volume Health

```bash
# Check volume status
kubectl mayastor get volumes -n openebs

# Check replica topology
kubectl mayastor get volume-replica-topologies -n openebs

# If any volumes show degraded, they should automatically rebuild
# Monitor rebuild progress
kubectl mayastor get rebuild-history <volume-id> -n openebs
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

#### 5.2 Verify Database Connectivity

```bash
# Get the cluster connection details
kubectl get service production-postgresql-rw -n postgresql-system

# Test connection from a pod
kubectl run -it --rm psql-test --image=postgres:17 --restart=Never -- \
  psql -h production-postgresql-rw.postgresql-system.svc.cluster.local -U app -d app -c "SELECT version();"
```

**Expected Output**: Connection successful, version information displayed.

#### 5.3 Check Monitoring Stack

```bash
# Check Prometheus pods
kubectl get pods -n monitoring

# Verify Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
# Open http://localhost:9090/targets in browser

# Check Grafana
kubectl port-forward -n monitoring svc/prometheus-stack-grafana 3000:80 &
# Open http://localhost:3000 in browser
```

#### 5.4 Check ArgoCD

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
# 1. Storage I/O errors - check diskpool status
# 2. WAL archiving failures - check S3 credentials
# 3. Recovery failures - may need to restore from backup

# Check storage status
kubectl get diskpools -n openebs
kubectl mayastor get volumes -n openebs

# Restart pod if needed
kubectl delete pod production-postgresql-1 -n postgresql-system
```

### OpenEBS Mayastor Issues

#### Diskpools Stuck in Unknown State

```bash
# Check io-engine pods
kubectl get pods -n openebs -l app=io-engine

# Check node labels
kubectl get nodes --show-labels | grep mayastor

# Restart io-engine on affected node
kubectl delete pod -n openebs -l app=io-engine,openebs.io/nodename=<node-name>

# Wait for diskpool to come online
kubectl get diskpools -n openebs -w
```

#### Volume Replicas Degraded

```bash
# Check replica status
kubectl mayastor get volume-replica-topologies -n openebs

# Volumes should automatically rebuild
# Monitor rebuild progress
kubectl mayastor get rebuild-history <volume-id> -n openebs

# If rebuild doesn't start automatically, check:
# 1. All diskpools are Online
# 2. Network connectivity between nodes
# 3. io-engine pods are running
```

#### Volume Mount Failures

```bash
# Check volume target status
kubectl mayastor get volumes -n openebs

# Check CSI node pods
kubectl get pods -n openebs -l app=mayastor-csi

# Check CSI driver logs
kubectl logs -n openebs <mayastor-csi-pod> -c mayastor-csi

# Common causes:
# 1. io-engine not ready on target node
# 2. Network connectivity issues
# 3. Volume in degraded state

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

### General Recovery Steps

#### If Cluster Fails to Come Up Cleanly

1. **Check Control Plane**:
   ```bash
   kubectl get nodes
   kubectl get pods -n kube-system
   ```

2. **Check Storage**:
   ```bash
   kubectl get diskpools -n openebs
   kubectl mayastor get pools -n openebs
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
   - Restart storage layer first (OpenEBS)
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
- **OpenEBS Mayastor ready**: 2-5 minutes after nodes are Ready
- **PostgreSQL cluster ready**: 3-5 minutes after storage is ready
- **Full cluster operational**: 15-30 minutes after power-on
- **Volume rebuilds** (if needed): Varies based on data size, typically 30-60 minutes

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
| 2025-11-03 | Initial document creation | Claude Code |

---

## References

- [MicroK8s Documentation](https://microk8s.io/docs)
- [Kubernetes Node Drain](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [OpenEBS Mayastor Maintenance](https://openebs.io/docs/user-guides/replicated-storage-user-guide/replicated-pv-mayastor/advanced-operations/kubectl-plugin)
- [CloudNativePG Kubernetes Upgrade](https://cloudnative-pg.io/documentation/current/kubernetes_upgrade/)
- [CloudNativePG Automated Failover](https://cloudnative-pg.io/documentation/current/failover/)

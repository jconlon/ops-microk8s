# MicroK8s Cluster Recovery Plan

> **HISTORICAL DOCUMENT**: This recovery plan documents the November 2025 incident when the cluster was using OpenEBS Mayastor storage. The cluster has since migrated to Rook/Ceph. This document is preserved for historical reference.

**Date Shutdown:** 2025-11-03 ~23:40 UTC
**Reason:** Hardware connection issues (whale node), disk issues (trout pool-trout)

---

## Pre-Shutdown State Summary

### Cluster Health
- **Nodes:** All 5 nodes were Ready (mullet, shamu, trout, tuna, whale)
- **PostgreSQL:** OFFLINE - 0/3 instances running
- **Storage:** CRITICAL - Faulted volumes, pool-trout failed to import
- **Backups:** Last successful backup: **2025-11-03 19:44:40Z** ✅

### Critical Issues at Shutdown
1. **whale node:** 1747 io-engine restarts - hardware connection suspected
2. **trout node:** pool-trout disk import failure - disk/pool corruption
3. **PostgreSQL volumes:** 2 Faulted, 1 Degraded
4. **Database:** Completely offline, no primary elected

### Data Safety
✅ **DATA IS SAFE:**
- PostgreSQL backup in S3: 2025-11-03 19:44:40Z
- All PVCs exist and are Bound
- Volume replicas exist (degraded but data intact)

⚠️ **Data Loss Window:**
- Any data written after 19:44:40Z (before cluster failure) may not be in backup
- Database was offline for ~5 hours before shutdown, so no new writes during that time

---

## Hardware Issues to Fix

### 1. whale Node (Priority: HIGH)
**Problem:** io-engine had 1747 restarts indicating hardware instability

**Actions to take:**
```bash
# After powering on whale:
ssh whale

# Check hardware connections
sudo dmesg | grep -i error
sudo journalctl -u snap.microk8s.daemon-kubelite -n 200

# Check disk connectivity
lsblk
ls -la /dev/disk/by-id/

# Check system resources
free -h
df -h
top
```

**Look for:**
- Disk I/O errors
- Memory errors
- CPU throttling
- Network interface issues
- USB/SATA cable connection problems

---

### 2. trout Node - pool-trout Disk (Priority: CRITICAL)
**Problem:** Disk pool cannot be imported by Mayastor

**Disk:** `/dev/disk/by-id/ata-WDC_WD40EZAZ-00SF3B0_WD-WX42D5122EVU`

**Actions to take:**
```bash
# After powering on trout:
ssh trout

# Check if disk is visible
lsblk | grep -i WD40
ls -la /dev/disk/by-id/ | grep WD40

# Check disk health (SMART)
sudo apt-get install -y smartmontools
sudo smartctl -a /dev/disk/by-id/ata-WDC_WD40EZAZ-00SF3B0_WD-WX42D5122EVU

# Check for errors in dmesg
sudo dmesg | tail -100 | grep -i "error\|fail\|ata"

# Check physical connections
# - Reseat SATA cable
# - Try different SATA port
# - Check power connector

# Check if LVM can see the pool
sudo lvs
sudo pvs
sudo vgs

# Check filesystem
sudo fsck -n /dev/disk/by-id/ata-WDC_WD40EZAZ-00SF3B0_WD-WX42D5122EVU
```

**Possible outcomes:**
- ✅ Disk is healthy → Pool should import after restart
- ⚠️ Cable/connection issue → Fix and retry
- ❌ SMART errors → Disk failing, needs replacement
- ❌ Filesystem corruption → May need pool recreation (DATA LOSS!)

---

## Startup Procedure (After Hardware Fixes)

### Phase 1: Start Control Plane Nodes

**Order:** Start these first (any order within control plane)

```bash
# Power on control plane nodes
# - whale (ONLY after fixing hardware issues)
# - trout (ONLY after fixing/checking disk)
# - mullet

# Wait 5-10 minutes for nodes to boot and become Ready
kubectl get nodes -w
```

**Expected:** All should show `Ready,SchedulingDisabled` (still cordoned)

---

### Phase 2: Start Worker Nodes

```bash
# Power on worker nodes
# - tuna
# - shamu

# Wait for nodes to become Ready
kubectl get nodes -w
```

---

### Phase 3: Verify Storage Recovery

```bash
# Check diskpools (CRITICAL: pool-trout must be Online)
kubectl get diskpools -n openebs

# Check io-engine pods
kubectl get pods -n openebs -l app=io-engine

# Check Mayastor volumes
kubectl mayastor get volumes -n openebs
```

**Expected:**
- All diskpools: **Online** (especially pool-trout!)
- All io-engine pods: **Running**

**If pool-trout is still Unknown/Offline:**
- Hardware fix didn't work
- See "Emergency: Pool Recreation" section below

---

### Phase 4: Uncordon Nodes

```bash
# Only uncordon if storage is healthy
kubectl uncordon mullet
kubectl uncordon shamu
kubectl uncordon trout
kubectl uncordon tuna
kubectl uncordon whale

# Verify
kubectl get nodes
```

All nodes should show `Ready` (no SchedulingDisabled)

---

### Phase 5: PostgreSQL Recovery

#### Option A: Automatic Recovery (if volumes recover)

```bash
# Check if PostgreSQL pods start automatically
kubectl get pods -n postgresql-system -w

# Check cluster status
kubectl get cluster production-postgresql -n postgresql-system

# Wait up to 10 minutes for cluster to become healthy
```

**If this works:** You're done! ✅

---

#### Option B: Restore from Backup (if volumes remain faulted)

**Use this if volumes don't recover or PostgreSQL won't start**

```bash
# 1. Delete the broken cluster
kubectl delete cluster production-postgresql -n postgresql-system

# 2. Delete the PVCs (they're faulted anyway)
kubectl delete pvc production-postgresql-1 production-postgresql-2 production-postgresql-3 -n postgresql-system

# 3. Wait for PVs to be cleaned up
kubectl get pv | grep postgresql

# 4. Recreate the cluster (will create new PVCs)
kubectl apply -f postgresql-gitops/cluster/postgresql-cluster.yaml

# 5. Wait for new cluster to come up
kubectl get pods -n postgresql-system -w

# 6. Restore from backup
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: production-postgresql
  namespace: postgresql-system
spec:
  instances: 3
  bootstrap:
    recovery:
      source: production-postgresql-backup
      recoveryTarget:
        targetTime: "2025-11-03 19:44:40+00:00"
  # ... rest of cluster spec from your config
EOF
```

**Data loss:** Max 5 hours (data after 19:44:40Z before cluster went offline)

---

## Emergency: Pool Recreation (LAST RESORT)

⚠️ **WARNING:** This destroys all data on pool-trout!

**Only do this if:**
1. Disk is physically healthy (SMART passed)
2. Pool import still fails after multiple retries
3. You've confirmed PostgreSQL backup is good
4. You accept losing any volume replicas on trout

```bash
# 1. Backup current state
kubectl get diskpool pool-trout -n openebs -o yaml > pool-trout-backup.yaml

# 2. Delete the diskpool
kubectl delete diskpool pool-trout -n openebs

# 3. Wait for cleanup
kubectl get diskpools -n openebs

# 4. Recreate the pool
kubectl apply -f openebs-gitops/diskpools/pool-trout.yaml

# 5. Verify new pool is Online
kubectl get diskpools -n openebs
```

After this, all volumes will need to rebuild replicas on trout (may take hours).

---

## Verification Checklist

After startup, verify everything is healthy:

```bash
# 1. All nodes Ready
kubectl get nodes

# 2. All diskpools Online
kubectl get diskpools -n openebs

# 3. All io-engine pods Running
kubectl get pods -n openebs -l app=io-engine

# 4. Volumes healthy (not Faulted/Degraded)
kubectl mayastor get volumes -n openebs

# 5. PostgreSQL cluster healthy
kubectl get cluster production-postgresql -n postgresql-system
kubectl get pods -n postgresql-system

# 6. Database accessible
kubectl run -it --rm psql-test --image=postgres:17 --restart=Never -- \
  psql -h production-postgresql-rw.postgresql-system.svc.cluster.local \
  -U app -d app -c "SELECT version();"

# 7. Monitoring stack
kubectl get pods -n monitoring

# 8. ArgoCD
kubectl get applications -n argocd
```

All should be **Healthy/Running/Online**

---

## Troubleshooting Common Issues

### Issue: pool-trout still Unknown after restart

**Cause:** Disk/pool corruption
**Solution:** See "Emergency: Pool Recreation" above

---

### Issue: whale io-engine keeps restarting

**Cause:** Hardware instability not fixed
**Solution:**
1. Check hardware connections again
2. Try different power supply
3. Check for overheating
4. May need to replace node

---

### Issue: PostgreSQL pods stuck in Init or CrashLoop

**Cause:** Volumes still faulted
**Solution:** Use Option B (Restore from Backup)

---

### Issue: Volumes stuck in Degraded/Faulted

**Cause:** Replicas can't sync
**Solution:** Wait for automatic rebuild (can take 1-2 hours)

Check rebuild progress:
```bash
kubectl mayastor get volume-replica-topologies -n openebs
kubectl mayastor get rebuild-history -n openebs
```

---

## Contact Information

- **Backup Location:** S3 bucket `s3://postgresql-microk8s-one/postgresql-backups/production/`
- **Last Good Backup:** 2025-11-03 19:44:40Z
- **Documentation:** `/home/jconlon/git/ops-microk8s/`
- **Shutdown State Files:** `/tmp/shutdown-*.txt` (on node where shutdown was initiated)

---

## Post-Recovery Actions

After cluster is healthy and stable for 24 hours:

1. **Create fresh backup**
   ```bash
   # Trigger manual backup
   kubectl apply -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: post-recovery-backup-$(date +%Y%m%d)
     namespace: postgresql-system
   spec:
     method: barmanObjectStore
     cluster:
       name: production-postgresql
   EOF
   ```

2. **Verify backup succeeded**
   ```bash
   kubectl get backups -n postgresql-system
   ```

3. **Monitor for 7 days** before attempting maintenance

4. **Review monitoring** for any recurring issues:
   - io-engine restart counts
   - Volume rebuild frequency
   - Disk I/O errors

---

## Lessons Learned

1. **Hardware monitoring needed** - whale's 1747 restarts should have triggered alerts
2. **Storage health checks** - pool import failures need better visibility
3. **Backup verification** - Test restores regularly
4. **Maintenance requires healthy cluster** - Cannot do maintenance in degraded state

---

**Good luck with the recovery! The backups are solid, so data is safe.**

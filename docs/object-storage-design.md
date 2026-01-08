# Ceph Object Storage (RGW) Architecture Design

**Date**: 2026-01-05
**Cluster**: MicroK8s 8-node (ops-microk8s)
**Storage Nodes**: gold, squid, puffer, carp (Dell R320)
**Available Drives**: 4x 4TB drives at /dev/sdc (one per node)

## Overview

This document outlines the architecture for adding S3-compatible object storage to the existing Rook/Ceph cluster using RADOS Gateway (RGW).

## Current State

- **Block Storage**: Operational on Dell R320 nodes using existing drives
  - 4 OSDs (osd-0 through osd-3) on gold, squid, puffer, carp
  - 3-way replication
  - Storage class: `rook-ceph-block`
- **New Resources**: 4x 4TB drives at /dev/sdc (clean and ready)
- **Total Raw Capacity**: ~16TB

## Architecture Design Options

### Option 1: Replicated Data Pool (Recommended for Simplicity)

**Configuration:**
- **Metadata Pool**: 3-way replication (required for reliability)
- **Data Pool**: 3-way replication
- **Usable Capacity**: ~5.3TB (16TB / 3)
- **Minimum OSDs Required**: 3
- **Failure Tolerance**: Can lose 1 OSD without data loss

**Pros:**
- Simpler configuration
- Better performance for small objects
- Consistent with existing block storage strategy
- Lower CPU overhead
- Easier to understand and troubleshoot

**Cons:**
- Lower storage efficiency (33% vs ~50% for erasure coding)
- Higher raw storage cost per TB

**YAML Configuration:**
```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: rook-ceph-rgw
  namespace: rook-ceph
spec:
  metadataPool:
    failureDomain: host
    replicated:
      size: 3
      requireSafeReplicaSize: true
    parameters:
      compression_mode: none

  dataPool:
    failureDomain: host
    replicated:
      size: 3
      requireSafeReplicaSize: true
    parameters:
      compression_mode: passive  # Enable compression for larger objects

  preservePoolsOnDelete: true

  gateway:
    type: s3
    port: 80
    instances: 2
    placement:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - rook-ceph-rgw
            topologyKey: kubernetes.io/hostname
    resources:
      limits:
        memory: "2Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
```

### Option 2: Erasure Coded Data Pool (Recommended for Capacity)

**Configuration:**
- **Metadata Pool**: 3-way replication (required for reliability)
- **Data Pool**: Erasure coding 2+2 (2 data chunks, 2 coding chunks)
- **Usable Capacity**: ~8TB (16TB / 2)
- **Minimum OSDs Required**: 4
- **Failure Tolerance**: Can lose 2 OSDs without data loss

**Pros:**
- 50% storage efficiency (better than replication)
- Better capacity utilization
- Higher durability (can lose 2 OSDs vs 1)
- Good for large objects (backups, media)

**Cons:**
- Higher CPU overhead for encoding/decoding
- Slightly slower for small object writes
- More complex recovery process
- Requires all 4 OSDs operational

**YAML Configuration:**
```yaml
apiVersion: ceph.rook.io/v1
kind: CephObjectStore
metadata:
  name: rook-ceph-rgw
  namespace: rook-ceph
spec:
  metadataPool:
    failureDomain: host
    replicated:
      size: 3
      requireSafeReplicaSize: true
    parameters:
      compression_mode: none

  dataPool:
    failureDomain: host
    erasureCoded:
      dataChunks: 2
      codingChunks: 2
    parameters:
      compression_mode: passive

  preservePoolsOnDelete: true

  gateway:
    type: s3
    port: 80
    instances: 2
    placement:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
              - key: app
                operator: In
                values:
                - rook-ceph-rgw
            topologyKey: kubernetes.io/hostname
    resources:
      limits:
        memory: "2Gi"
      requests:
        cpu: "500m"
        memory: "1Gi"
```

## RGW Gateway Deployment Strategy

### Gateway Instances: 2 (Recommended)

**Rationale:**
- High availability (one instance can fail)
- Load balancing across instances
- Better throughput for concurrent requests
- Anti-affinity ensures they run on different nodes

**Placement Strategy:**
- Deploy on non-storage nodes (mullet, trout, tuna, whale) to avoid resource contention
- Use podAntiAffinity to spread across different hosts
- Consider nodeSelector if you want to restrict to specific nodes

**Resource Allocation:**
- CPU: 500m request, 2000m limit (per instance)
- Memory: 1Gi request, 2Gi limit (per instance)
- Adjust based on expected load

### Alternative: 1 Instance (Minimal)

For testing or low-usage scenarios:
- Lower resource consumption
- Simpler configuration
- No HA (single point of failure)

## Networking Configuration

### MetalLB IP Assignment

Allocate a dedicated IP from your MetalLB range (192.168.0.200-192.168.0.220):

**Recommended:** `192.168.0.210` (or next available)

### Service Configuration

```yaml
apiVersion: v1
kind: Service
metadata:
  name: rook-ceph-rgw-rook-ceph-rgw
  namespace: rook-ceph
  annotations:
    metallb.universe.tf/address-pool: default
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.0.210
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: https
    port: 443
    targetPort: 443
  selector:
    app: rook-ceph-rgw
    rook_object_store: rook-ceph-rgw
```

### DNS Configuration

Add DNS entry (via PiHole or router):
```
rgw.verticon.com -> 192.168.0.210
s3.verticon.com  -> 192.168.0.210
```

### SSL/TLS (Optional but Recommended)

Use cert-manager to provision TLS certificate:
```bash
# Install cert-manager if not already installed
microk8s enable cert-manager

# Create certificate for RGW
kubectl apply -f rook-ceph/rgw-certificate.yaml
```

## S3 Bucket Structure and Use Cases

### Primary Use Cases

1. **PostgreSQL Backups** (Existing use case)
   - Bucket: `postgresql-backups`
   - Lifecycle policy: Retain 30 days
   - Quota: 500GB

2. **Application Backups**
   - Bucket: `app-backups`
   - Lifecycle policy: Retain 90 days
   - Quota: 1TB

3. **Media Storage**
   - Bucket: `media-files`
   - Lifecycle policy: Indefinite
   - Quota: 2TB

4. **Log Archive**
   - Bucket: `log-archive`
   - Lifecycle policy: Retain 180 days, then delete
   - Quota: 500GB

### User and Access Management

Create users per application/service:

```yaml
---
apiVersion: ceph.rook.io/v1
kind: CephObjectStoreUser
metadata:
  name: postgresql-backup-user
  namespace: rook-ceph
spec:
  store: rook-ceph-rgw
  displayName: "PostgreSQL Backup Service"
  quotas:
    maxBuckets: 5
    maxSize: "500Gi"
    maxObjects: 100000
---
apiVersion: ceph.rook.io/v1
kind: CephObjectStoreUser
metadata:
  name: app-backup-user
  namespace: rook-ceph
spec:
  store: rook-ceph-rgw
  displayName: "Application Backup Service"
  quotas:
    maxBuckets: 10
    maxSize: "1Ti"
    maxObjects: 500000
```

## Storage Pool Sizing

### With 3-Way Replication (Option 1)

| Pool Type | Size | Raw Used | Usable |
|-----------|------|----------|--------|
| Metadata  | 3-way | ~100GB | ~33GB |
| Data      | 3-way | ~16TB | ~5.3TB |
| **Total** | | **~16TB** | **~5.3TB** |

### With Erasure Coding 2+2 (Option 2)

| Pool Type | Size | Raw Used | Usable |
|-----------|------|----------|--------|
| Metadata  | 3-way | ~100GB | ~33GB |
| Data      | EC 2+2 | ~16TB | ~8TB |
| **Total** | | **~16TB** | **~8TB** |

## Performance Considerations

### Expected Performance

**With Replication:**
- Small objects (<1MB): 200-500 ops/sec
- Large objects (>10MB): 100-200 MB/s per client
- Latency: 10-50ms (LAN)

**With Erasure Coding:**
- Small objects (<1MB): 100-300 ops/sec (slower due to encoding)
- Large objects (>10MB): 150-250 MB/s per client
- Latency: 15-75ms (LAN)

### Optimization Tips

1. **Enable compression** for large objects (already in config with `passive` mode)
2. **Use multiple RGW instances** for better throughput
3. **Tune RGW parameters** in CephCluster if needed
4. **Monitor OSD performance** - ensure network bandwidth is adequate

## Monitoring and Metrics

### Key Metrics to Track

1. **RGW Metrics:**
   - Request rate (GET, PUT, DELETE)
   - Latency (p50, p95, p99)
   - Error rates (4xx, 5xx)
   - Bandwidth utilization

2. **Pool Metrics:**
   - Pool usage (metadata, data)
   - IOPS per pool
   - Recovery/backfill status

3. **OSD Metrics:**
   - OSD-4 through OSD-7 utilization
   - Network bandwidth
   - Disk I/O

### Grafana Dashboards

Add RGW-specific dashboards:
- Ceph RGW Overview
- S3 API Performance
- Object Storage Capacity

## Migration Plan from External S3

If currently using AWS S3 or other external S3:

1. **Phase 1: Deploy RGW** (test with non-critical data)
2. **Phase 2: Migrate PostgreSQL backups** (already configured for S3)
3. **Phase 3: Migrate application backups**
4. **Phase 4: New applications use internal S3**

### Cost Savings Estimate

If migrating from AWS S3:
- Storage: $0.023/GB/month × 5000GB = $115/month saved
- Requests: Variable, but typically $10-50/month
- **Total potential savings: $125-165/month ($1,500-2,000/year)**

## Recommendation

### For General Use: **Option 1 (Replicated)**

**Choose if:**
- You prioritize simplicity and performance
- Workload includes many small objects
- 5.3TB usable capacity is sufficient
- You want consistency with existing block storage

### For Maximum Capacity: **Option 2 (Erasure Coded 2+2)**

**Choose if:**
- You need maximum storage efficiency (8TB vs 5.3TB)
- Workload is primarily large objects (backups, media)
- You can tolerate slightly higher CPU usage
- You want better durability (tolerate 2 OSD failures)

## Next Steps

1. **Decision:** Choose replication strategy (Option 1 or 2)
2. **Prepare:** Finalize MetalLB IP allocation (suggest: 192.168.0.210)
3. **Deploy:** Create Rook configuration files
4. **Configure:** Set up S3 users and buckets
5. **Test:** Validate S3 API compatibility
6. **Monitor:** Add Grafana dashboards
7. **Migrate:** Move workloads from external S3 (if applicable)

## Files to Create

```
rook-ceph/object-storage/
├── ceph-object-store.yaml       # Main ObjectStore definition
├── rgw-service.yaml              # LoadBalancer service
├── users/
│   ├── postgresql-user.yaml     # PostgreSQL backup user
│   └── app-user.yaml            # Application user
└── monitoring/
    ├── servicemonitor.yaml      # Prometheus metrics
    └── grafana-dashboard.yaml   # RGW dashboard
```

## Scalability: Adding More Drives Later

### How Easy Is It to Add More OSDs?

**Short answer:** Very easy! Adding drives to an existing Ceph cluster is straightforward regardless of which option you choose.

### The Process

1. **Install new drives** on nodes (e.g., add /dev/sdd to each node)
2. **Update CephCluster config** to include the new devices
3. **Rook automatically creates new OSDs** from the drives
4. **Ceph automatically rebalances data** across all OSDs (old + new)
5. **No downtime** - happens in the background

### Example: Adding 4 More Drives

If you later add 4x 4TB drives at /dev/sdd:

```yaml
# Update your CephCluster to add new devices
storage:
  devices:
    - name: "/dev/sdc"  # Existing drives
    - name: "/dev/sdd"  # NEW drives
```

Rook will automatically:
- Create OSD-4, OSD-5, OSD-6, OSD-7 on the new drives
- Rebalance data across all 8 OSDs
- Increase usable capacity

### Impact on Each Option

#### Option 1: Replication (size: 3)

**Adding drives:**
```
Current:  4 OSDs × 4TB = 16TB raw → 5.3TB usable (with 3-way replication)
After:    8 OSDs × 4TB = 32TB raw → 10.6TB usable (still 3-way replication)
Process:  Easy ✅ Just add drives and Ceph rebalances
```

**Flexibility:**
- ✅ Can change replica count later (from 3 to 2 or 4) if desired
- ✅ Works with any number of OSDs (minimum 3)
- ✅ Very predictable scaling: double drives = double capacity

**Winner for incremental scaling:** Replication is more flexible

#### Option 2: Erasure Coding (2+2)

**Adding drives (keeping same EC scheme):**
```
Current:  4 OSDs × 4TB = 16TB raw → 8TB usable (with EC 2+2)
After:    8 OSDs × 4TB = 32TB raw → 16TB usable (still EC 2+2)
Process:  Easy ✅ Just add drives and Ceph rebalances
```

**Flexibility:**
- ⚠️ **CANNOT change EC parameters** (2+2) after pool creation
- ⚠️ To change from EC 2+2 to EC 4+2, you must:
  1. Create a new pool with EC 4+2
  2. Copy all data to the new pool
  3. Delete the old pool
  4. Update RGW to use the new pool
- ✅ Adding drives with same EC scheme (2+2) is easy
- ⚠️ EC schemes require specific OSD counts (2+2 needs 4+, 4+2 needs 6+)

**Winner for future-proofing:** Replication is more flexible

### Scaling Scenarios

#### Scenario 1: Add 4 More Drives (8 Total)

**Option 1 (Replication):**
- Add drives → automatic rebalance
- Capacity: 5.3TB → 10.6TB
- **Effort: Minimal** ✅

**Option 2 (EC 2+2):**
- Add drives → automatic rebalance
- Capacity: 8TB → 16TB
- **Effort: Minimal** ✅
- Could consider migrating to EC 4+2 for better efficiency

#### Scenario 2: Add 8 More Drives (12 Total)

**Option 1 (Replication):**
- Add drives → automatic rebalance
- Capacity: 5.3TB → 16TB
- **Effort: Minimal** ✅

**Option 2 (EC 2+2):**
- Keep EC 2+2: Capacity: 8TB → 24TB ✅
- Migrate to EC 4+2: Capacity: 8TB → 32TB (better efficiency!)
- **Effort: Minimal for 2+2, Moderate for migration to 4+2** ⚠️

### When EC Becomes More Efficient

Erasure coding scales better with more drives:

| Total OSDs | EC 2+2 Usable | EC 4+2 Usable | EC 8+3 Usable | Replication (3x) Usable |
|------------|---------------|---------------|---------------|-------------------------|
| 4 drives   | 50% (8TB)     | ❌ Not enough | ❌ Not enough | 33% (5.3TB)             |
| 8 drives   | 50% (16TB)    | 67% (21TB) ✨ | ❌ Not enough | 33% (10.6TB)            |
| 12 drives  | 50% (24TB)    | 67% (32TB) ✨ | 73% (35TB) ✨ | 33% (16TB)              |
| 16 drives  | 50% (32TB)    | 67% (43TB) ✨ | 73% (47TB) ✨ | 33% (21TB)              |

**Key insight:** With more drives, you can use better EC schemes (like 4+2 or 8+3) for higher efficiency.

### Migration Path Comparison

#### Starting with Replication (Option 1)

```
Day 1:     4 drives, 3-way replication → 5.3TB usable
Year 1:    Add 4 drives, 3-way replication → 10.6TB usable
Year 2:    Add 8 drives, 3-way replication → 21TB usable
           OR migrate to EC 4+2 → 43TB usable (requires data migration)
```

**Pros:**
- ✅ Easiest path - just keep adding drives
- ✅ No data migration needed
- ✅ Can change strategy later if desired

**Cons:**
- ⚠️ Lower storage efficiency as you grow
- ⚠️ Migration to EC requires downtime and effort

#### Starting with Erasure Coding 2+2 (Option 2)

```
Day 1:     4 drives, EC 2+2 → 8TB usable
Year 1:    Add 4 drives, EC 2+2 → 16TB usable
           OR migrate to EC 4+2 → 21TB usable (better efficiency!)
Year 2:    Add 8 drives, EC 4+2 → 43TB usable
           OR migrate to EC 8+3 → 47TB usable (even better!)
```

**Pros:**
- ✅ Better storage efficiency from day 1
- ✅ Can migrate to better EC schemes as you grow
- ✅ Better for large-scale deployments

**Cons:**
- ⚠️ Changing EC scheme requires data migration
- ⚠️ Stuck with 2+2 unless you migrate
- ⚠️ More complex troubleshooting

### Recommendation Based on Growth Plans

**Choose Replication (Option 1) if:**
- ❓ Uncertain about future growth
- 🔄 Want maximum flexibility to change strategies
- 🎯 Prefer simplicity over efficiency
- 📈 Planning to add drives incrementally (1-2 at a time)

**Choose Erasure Coding 2+2 (Option 2) if:**
- ✅ Confident you'll add drives in batches (4+ at a time)
- 💾 Storage efficiency is a priority (8TB vs 5.3TB matters)
- 🎯 Comfortable with migration if you want better EC schemes later
- 📈 Expect to grow to 8+ drives soon (can migrate to EC 4+2)

## Bottom Line on Scalability

**Both options scale easily!** The difference is:

1. **Replication:** 
   - Adding drives: ⭐⭐⭐⭐⭐ (Easiest)
   - Changing strategy later: ⭐⭐⭐⭐ (Easy, but requires migration)
   - Efficiency at scale: ⭐⭐⭐ (Good, but lower)

2. **Erasure Coding:** 
   - Adding drives: ⭐⭐⭐⭐⭐ (Easiest, same EC scheme)
   - Changing strategy later: ⭐⭐⭐ (Moderate, requires migration)
   - Efficiency at scale: ⭐⭐⭐⭐⭐ (Excellent, especially with 8+ drives)

**My Updated Recommendation:** 

Start with **Replication (Option 1)** if you value **maximum flexibility** and plan to grow incrementally.

Start with **Erasure Coding 2+2 (Option 2)** if you want **better capacity now** (8TB vs 5.3TB) and expect to add drives in the future (making migration to EC 4+2 worthwhile).


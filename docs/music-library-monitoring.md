# Music Library Monitoring in Grafana

## Overview

The music library (72 GiB) is stored in Ceph Object Storage (RGW) and is monitored through the existing Prometheus/Grafana stack.

## Storage Layout

### RGW Buckets
```
ceph-rgw/
├── music-library/       72 GiB (3,209 objects) ← Music Library
├── restic-backups/      79 GiB (16,852 objects) ← PostgreSQL backups
└── test-bucket/         14 B (1 object)
─────────────────────────────────────────────────
Total:                   ~151 GiB
```

### Ceph Pool Mapping

**Pool 10: `rook-ceph-rgw.rgw.buckets.data`**
- **Raw Size**: 304.6 GB (shown in Prometheus)
- **Actual Data**: ~151 GiB (72 GiB music + 79 GiB backups)
- **Storage Overhead**: 2x due to erasure coding (ec:2+2)
- **Compression**: Passive compression enabled
- **Replication**: 2 data chunks + 2 parity chunks = 4 total chunks

## Grafana Dashboard

### Access
- **URL**: https://grafana.verticon.com
- **Dashboard**: Ceph Cluster Overview
- **Direct Link**: https://grafana.verticon.com/d/rook-ceph-cluster/ceph-cluster

### Key Metrics

#### 1. Total RGW Storage
**Metric**: `ceph_pool_bytes_used{pool="rook-ceph-rgw.rgw.buckets.data"}`
- **Current Value**: 304.6 GB (includes music library + backups + overhead)
- **Pool ID**: 10

#### 2. RGW Operations
Available metrics:
- `ceph_rgw_get` - GET requests (downloads)
- `ceph_rgw_put` - PUT requests (uploads)
- `ceph_rgw_get_b` - GET bytes transferred
- `ceph_rgw_put_b` - PUT bytes transferred
- `ceph_rgw_req` - Total requests
- `ceph_rgw_qlen` - Queue length
- `ceph_rgw_cache_hit` / `ceph_rgw_cache_miss` - Cache performance

#### 3. Cluster Health
**Metric**: `ceph_health_status`
- **Current**: HEALTH_OK

## Viewing Music Library Storage

### In Grafana

1. Navigate to: https://grafana.verticon.com/d/rook-ceph-cluster/ceph-cluster

2. Look for panel: **"Pool Usage"** or **"Pool Bytes Used"**
   - Filter by pool: `rook-ceph-rgw.rgw.buckets.data`
   - Current value: ~304 GB

3. **Note**: Individual bucket metrics (music-library vs restic-backups) are not exposed by Ceph RGW exporter
   - Prometheus shows total pool usage only
   - Use `mc du` commands for per-bucket breakdown

### Via Command Line

```bash
# Total RGW pool usage (from Prometheus perspective)
curl -s 'https://prometheus.verticon.com/api/v1/query?query=ceph_pool_bytes_used{pool="rook-ceph-rgw.rgw.buckets.data"}' | jq -r '.data.result[0].value[1]'

# Per-bucket breakdown (actual data)
devbox run -- mc du ceph-rgw/music-library/
devbox run -- mc du ceph-rgw/restic-backups/
devbox run -- mc du ceph-rgw/test-bucket/

# All buckets summary
for bucket in music-library restic-backups test-bucket; do
  echo "=== $bucket ==="
  devbox run -- mc du ceph-rgw/$bucket/
  echo
done
```

### Via Prometheus UI

1. Go to: https://prometheus.verticon.com
2. Query: `ceph_pool_bytes_used{pool="rook-ceph-rgw.rgw.buckets.data"}`
3. Graph will show total RGW storage over time

## Storage Calculation

### Music Library Breakdown
```
User Data (mc shows):          72 GiB
Erasure Coding Overhead:       ×2 (ec:2+2 = 4 chunks for 2 data)
Actual Disk Usage:             ~144 GB

Plus restic-backups:           79 GiB × 2 = ~158 GB
Plus test-bucket:              negligible
─────────────────────────────────────────────
Total Pool Usage:              ~302 GB (matches Prometheus)
```

## Monitoring Checklist

✅ **Music library is visible in Grafana**
- Part of pool 10 (`rook-ceph-rgw.rgw.buckets.data`)
- Contributes 72 GiB to the 151 GiB total data
- Shows as ~144 GB in pool usage (with ec:2+2 overhead)

✅ **Metrics Available**
- Total RGW pool usage: Yes
- RGW operation rates: Yes (GET/PUT/requests)
- Per-bucket usage: No (use `mc du` instead)

✅ **Alerting Capability**
- Can create alerts on total pool usage
- Can monitor RGW service health
- Can track operation rates

## Limitations

### No Per-Bucket Metrics
Ceph RGW Prometheus exporter does **not** export per-bucket metrics. Available workarounds:

1. **Use mc du periodically**
   ```bash
   # Run via cron or systemd timer
   devbox run -- mc du ceph-rgw/music-library/
   ```

2. **Parse RGW admin API** (advanced)
   ```bash
   # Requires RGW admin credentials
   radosgw-admin bucket stats --bucket=music-library
   ```

3. **Custom exporter** (not implemented)
   - Would need to query RGW admin API
   - Export per-bucket metrics to Prometheus

## Creating Custom Dashboard Panel (Optional)

If you want a dedicated music library panel in Grafana:

### Panel 1: Total RGW Storage
```promql
# Query
ceph_pool_bytes_used{pool="rook-ceph-rgw.rgw.buckets.data"}

# Panel Type: Stat or Gauge
# Title: "RGW Object Storage"
# Unit: bytes (IEC)
```

### Panel 2: RGW Operations
```promql
# Query
rate(ceph_rgw_get[5m])

# Panel Type: Graph
# Title: "RGW GET Operations/sec"
# Legend: {{instance}}
```

### Panel 3: Data Transfer
```promql
# Query
rate(ceph_rgw_get_b[5m]) + rate(ceph_rgw_put_b[5m])

# Panel Type: Graph
# Title: "RGW Network Throughput"
# Unit: bytes/sec (IEC)
```

## Verification Commands

```bash
# 1. Check music library size
devbox run -- mc du ceph-rgw/music-library/

# 2. Check total RGW pool usage in Prometheus
curl -s 'https://prometheus.verticon.com/api/v1/query?query=ceph_pool_bytes_used{pool="rook-ceph-rgw.rgw.buckets.data"}' | jq '.data.result[0].value'

# 3. Check Ceph cluster health
kubectl get cephcluster -n rook-ceph -o jsonpath='{.status.ceph.health}'

# 4. List all RGW buckets
devbox run -- mc ls ceph-rgw/

# 5. Check RGW service status
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw
```

## Conclusion

**Phase 7 Complete**: ✅

The music library (72 GiB) **is being monitored** in Prometheus/Grafana:
- Visible in pool 10 metrics (`rook-ceph-rgw.rgw.buckets.data`)
- RGW operation metrics available
- Storage usage tracked over time
- Dashboard accessible at https://grafana.verticon.com

**Limitation**: Individual bucket metrics not available (this is a Ceph RGW limitation, not a monitoring stack issue)

**Workaround**: Use `mc du ceph-rgw/music-library/` for per-bucket statistics

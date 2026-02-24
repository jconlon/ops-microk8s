# PostgreSQL Backup Configuration

This directory contains the configuration for automated PostgreSQL backups using CloudNativePG and internal Ceph S3 (RGW).

## Overview

- **Backup Method**: Barman with internal Ceph S3 object storage
- **S3 Endpoint**: `http://rook-ceph-rgw-rook-ceph-rgw.rook-ceph.svc:80` (in-cluster)
- **S3 Bucket**: `postgresql-backups` (on Ceph RGW at 192.168.0.204)
- **Destination Path**: `s3://postgresql-backups/production/`
- **Schedule**: Daily at 2 AM
- **Retention**: 30 days
- **Compression**: gzip for both WAL and data
- **Target**: Primary instance

## Credentials

S3 credentials are stored in Google Secret Manager and created as a Kubernetes secret
out-of-band via teller (not managed by ArgoCD).

Secret name: `ceph-s3-credentials` in `postgresql-system` namespace.

To recreate the secret (from `ops-microk8s` root directory):

```bash
teller run --config teller/.teller-postgresql.yml -- bash -c 'kubectl create secret generic ceph-s3-credentials \
  --namespace postgresql-system \
  --from-literal=ACCESS_KEY_ID="$ACCESS_KEY_ID" \
  --from-literal=ACCESS_SECRET_KEY="$ACCESS_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -'
```

Google Secret Manager keys:
- `access-key-ceph-lab` → `ACCESS_KEY_ID`
- `secret-key-ceph-lab` → `ACCESS_SECRET_KEY`

## ArgoCD

This directory is managed by the `postgresql-backup` ArgoCD application with `prune: false`
so the teller-managed `ceph-s3-credentials` secret is not deleted on sync.

## Verification

### Check Backup Status

```bash
# Cluster backup summary
kubectl cnpg status production-postgresql -n postgresql-system

# List all backups
kubectl get backups -n postgresql-system

# Check ScheduledBackup status
kubectl get scheduledbackup production-postgresql-daily-backup -n postgresql-system
```

### Trigger Manual Backup

```bash
kubectl cnpg backup production-postgresql -n postgresql-system
```

### Verify S3 Contents

```bash
devbox run -- mc ls ceph-rgw/postgresql-backups/production/
devbox run -- mc ls ceph-rgw/postgresql-backups/production/wals/
```

## Restore Procedure

Create a new cluster from backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: restored-cluster
  namespace: postgresql-system
spec:
  instances: 3
  bootstrap:
    recovery:
      source: production-postgresql-backup
  storage:
    size: 120Gi
    storageClass: rook-ceph-block
  externalClusters:
    - name: production-postgresql-backup
      barmanObjectStore:
        destinationPath: "s3://postgresql-backups/production/"
        endpointURL: "http://rook-ceph-rgw-rook-ceph-rgw.rook-ceph.svc:80"
        s3Credentials:
          accessKeyId:
            name: ceph-s3-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: ceph-s3-credentials
            key: ACCESS_SECRET_KEY
```

## Files

- `scheduled-backup.yaml` — Daily backup schedule (2 AM, with immediate trigger on creation)
- `postgresql-backup-pvc.yaml` — Local PVC for backup cache (optional)
- `../cluster/production-postgresql-cluster.yaml` — Cluster with barmanObjectStore configuration

## Troubleshooting

### WAL Archiving Not Working

```bash
# Check cluster status
kubectl cnpg status production-postgresql -n postgresql-system

# Check pod logs
kubectl logs -n postgresql-system production-postgresql-1 -c postgres | grep archive
```

### Backup Fails

- Verify `ceph-s3-credentials` secret exists in `postgresql-system`
- Verify bucket exists: `devbox run -- mc ls ceph-rgw/postgresql-backups/`
- Check Ceph RGW service is reachable from postgresql pods

## References

- [CloudNativePG Backup Documentation](https://cloudnative-pg.io/documentation/current/backup/)
- [Rook/Ceph Object Storage](../../rook-ceph/object-storage/)

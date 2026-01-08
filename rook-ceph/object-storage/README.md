# Ceph Object Storage (RGW) - GitOps Configuration

This directory contains the Rook/Ceph Object Storage (RADOS Gateway) configuration managed via ArgoCD.

## Architecture

- **Storage Strategy**: Erasure Coding 2+2 (2 data chunks + 2 coding chunks)
- **Raw Capacity**: 16TB (4x 4TB drives at /dev/sdc on gold, squid, puffer, carp)
- **Usable Capacity**: ~8TB (50% efficiency)
- **Failure Tolerance**: Can lose 2 OSDs without data loss
- **RGW Instances**: 2 (HA with load balancing)
- **S3 Endpoint**: http://192.168.0.204 (MetalLB LoadBalancer)

## Files

```
object-storage/
├── ceph-object-store.yaml       # CephObjectStore CRD (EC 2+2 configuration)
├── rgw-service.yaml              # LoadBalancer service (MetalLB IP: 192.168.0.204)
├── postgresql-user.yaml          # S3 user for PostgreSQL backups (500GB quota)
├── app-user.yaml                 # S3 user for application backups (1TB quota)
├── servicemonitor.yaml           # Prometheus ServiceMonitor for RGW metrics
└── README.md                     # This file
```

## Prerequisites

1. ✅ Rook/Ceph operator installed and running (managed by ArgoCD)
2. ✅ Ceph cluster healthy (HEALTH_OK)
3. ✅ 4 clean drives at /dev/sdc on gold, squid, puffer, carp
4. ✅ MetalLB configured with 192.168.0.204 available
5. ✅ ArgoCD installed and managing cluster

## Deployment (GitOps)

### Via ArgoCD

```bash
# Apply the ArgoCD Application
kubectl apply -f argoCD-apps/rook-ceph-apps/ceph-object-storage-app.yaml

# Wait for sync
devbox run -- argocd app sync ceph-object-storage

# Monitor deployment
devbox run -- argocd app get ceph-object-storage
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw -w
```

## Verification

### Check RGW Pods

```bash
# Should see 2 RGW pods running
kubectl get pods -n rook-ceph -l app=rook-ceph-rgw

# Expected output:
# NAME                                     READY   STATUS    RESTARTS   AGE
# rook-ceph-rgw-rook-ceph-rgw-a-xxxxx     2/2     Running   0          2m
# rook-ceph-rgw-rook-ceph-rgw-b-xxxxx     2/2     Running   0          2m
```

### Check LoadBalancer Service

```bash
# Verify external IP is assigned
kubectl get svc rook-ceph-rgw-external -n rook-ceph

# Expected output:
# NAME                     TYPE           EXTERNAL-IP       PORT(S)
# rook-ceph-rgw-external   LoadBalancer   192.168.0.204     80:xxxxx/TCP
```

### Test S3 Endpoint

```bash
# Should return XML (means RGW is responding)
curl http://192.168.0.204
```

## Accessing S3 Credentials

After deployment, Rook automatically creates secrets with S3 access keys:

### PostgreSQL Backup User

```bash
# Get access credentials
echo "Access Key: $(kubectl get secret postgresql-backup-user -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)"
echo "Secret Key: $(kubectl get secret postgresql-backup-user -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)"
```

### Application Backup User

```bash
# Get access credentials
echo "Access Key: $(kubectl get secret app-backup-user -n rook-ceph -o jsonpath='{.data.AccessKey}' | base64 -d)"
echo "Secret Key: $(kubectl get secret app-backup-user -n rook-ceph -o jsonpath='{.data.SecretKey}' | base64 -d)"
```

## Using MinIO Client (mc)

The MinIO client (`mc`) provides a modern, user-friendly CLI for S3-compatible storage.

### Installation

**On Ubuntu/Debian:**
```bash
# Download MinIO client
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# Verify installation
mc --version
```

**On macOS:**
```bash
brew install minio/stable/mc
```

**On Windows:**
```powershell
# Download from https://dl.min.io/client/mc/release/windows-amd64/mc.exe
# Add to PATH
```

### Configuration

Add the Ceph RGW endpoint as an alias:

```bash
# Get credentials first (from secrets above)
export ACCESS_KEY="<your-access-key>"
export SECRET_KEY="<your-secret-key>"

# Configure mc alias for RGW
mc alias set ceph-rgw http://192.168.0.204 $ACCESS_KEY $SECRET_KEY

# Or with DNS (if configured)
mc alias set ceph-rgw http://rgw.verticon.com $ACCESS_KEY $SECRET_KEY

# Test connection
mc admin info ceph-rgw
```

**Create a persistent config:**

```bash
# The alias is saved in ~/.mc/config.json
# You can verify it:
cat ~/.mc/config.json

# Or export for team use:
mc alias export ceph-rgw > ceph-rgw-alias.json
# Share ceph-rgw-alias.json with team (securely!)
# Import on other machines:
mc alias import ceph-rgw ceph-rgw-alias.json
```

### Basic Operations

#### List Buckets

```bash
# List all buckets
mc ls ceph-rgw

# List with details (size, date)
mc ls ceph-rgw --summarize
```

#### Create Bucket

```bash
# Create a new bucket
mc mb ceph-rgw/my-bucket

# Create with region (optional, for compatibility)
mc mb ceph-rgw/my-bucket --region=us-east-1
```

#### Upload Files

```bash
# Upload single file
mc cp file.txt ceph-rgw/my-bucket/

# Upload directory (recursive)
mc cp --recursive ./backup-data/ ceph-rgw/my-bucket/backup/

# Upload with progress
mc cp --progress large-file.tar.gz ceph-rgw/my-bucket/

# Upload multiple files with wildcard
mc cp *.jpg ceph-rgw/my-bucket/photos/
```

#### Download Files

```bash
# Download single file
mc cp ceph-rgw/my-bucket/file.txt ./

# Download directory (recursive)
mc cp --recursive ceph-rgw/my-bucket/backup/ ./restored-backup/

# Download with resume support
mc cp --continue ceph-rgw/my-bucket/large-file.tar.gz ./
```

#### List Objects

```bash
# List objects in bucket
mc ls ceph-rgw/my-bucket

# List recursively
mc ls --recursive ceph-rgw/my-bucket

# List with human-readable sizes
mc ls ceph-rgw/my-bucket --humanize

# List with full details
mc ls ceph-rgw/my-bucket --recursive --versions
```

#### Delete Objects

```bash
# Delete single object
mc rm ceph-rgw/my-bucket/file.txt

# Delete directory (recursive)
mc rm --recursive ceph-rgw/my-bucket/old-backups/

# Delete with confirmation
mc rm --recursive --force ceph-rgw/my-bucket/temp/

# Delete bucket (must be empty)
mc rb ceph-rgw/my-bucket

# Force delete bucket with contents
mc rb --force ceph-rgw/my-bucket
```

#### Copy Between Buckets

```bash
# Copy within same RGW
mc cp ceph-rgw/source-bucket/file.txt ceph-rgw/dest-bucket/

# Mirror directory (sync)
mc mirror ceph-rgw/source-bucket/ ceph-rgw/dest-bucket/

# Copy from/to local filesystem
mc cp ./local-file.txt ceph-rgw/my-bucket/
```

#### Get Object Metadata

```bash
# Show file info
mc stat ceph-rgw/my-bucket/file.txt

# Show file hash
mc cat ceph-rgw/my-bucket/file.txt | md5sum
```

### Advanced Operations

#### Bucket Policies

```bash
# Get bucket policy
mc policy get ceph-rgw/my-bucket

# Set bucket to public read
mc policy set download ceph-rgw/my-bucket

# Set bucket to public read-write
mc policy set public ceph-rgw/my-bucket

# Set bucket to private
mc policy set private ceph-rgw/my-bucket

# Custom policy (JSON)
cat > policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "*"},
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::my-bucket/public/*"
    }
  ]
}
EOF
mc policy set-json policy.json ceph-rgw/my-bucket
```

#### Object Versioning

```bash
# Enable versioning
mc version enable ceph-rgw/my-bucket

# Check versioning status
mc version info ceph-rgw/my-bucket

# List versions
mc ls --versions ceph-rgw/my-bucket

# Suspend versioning
mc version suspend ceph-rgw/my-bucket
```

#### Find Files

```bash
# Find files by name
mc find ceph-rgw/my-bucket --name "*.jpg"

# Find files by size
mc find ceph-rgw/my-bucket --larger 100MB

# Find files older than 30 days
mc find ceph-rgw/my-bucket --older-than 30d

# Find and delete
mc find ceph-rgw/my-bucket --name "*.tmp" --exec "mc rm {}"
```

#### Monitoring and Watch

```bash
# Watch bucket events
mc watch ceph-rgw/my-bucket

# Watch with events (put, get, delete)
mc watch ceph-rgw/my-bucket --events put,get,delete

# Monitor disk usage
mc du ceph-rgw/my-bucket

# Continuous monitoring
watch -n 10 mc du --depth 2 ceph-rgw/my-bucket
```

### Backup and Sync Workflows

#### Backup Local Directory to RGW

```bash
# One-time backup
mc cp --recursive /home/user/documents/ ceph-rgw/backups/documents/

# Sync (mirror) with deletion
mc mirror --remove /home/user/documents/ ceph-rgw/backups/documents/

# Sync without deletion
mc mirror /home/user/documents/ ceph-rgw/backups/documents/

# Scheduled backup (add to cron)
0 2 * * * /usr/local/bin/mc mirror --remove /home/user/documents/ ceph-rgw/backups/documents/
```

#### Restore from RGW

```bash
# Restore specific file
mc cp ceph-rgw/backups/documents/important.txt /home/user/restored/

# Restore entire directory
mc mirror ceph-rgw/backups/documents/ /home/user/restored-documents/

# Restore with verification
mc mirror --md5 ceph-rgw/backups/documents/ /home/user/restored-documents/
```

#### Database Backup Example

```bash
#!/bin/bash
# Backup PostgreSQL to RGW using mc

BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="postgres_backup_${BACKUP_DATE}.sql.gz"

# Create backup
pg_dump mydatabase | gzip > /tmp/${BACKUP_FILE}

# Upload to RGW
mc cp /tmp/${BACKUP_FILE} ceph-rgw/database-backups/

# Cleanup local
rm /tmp/${BACKUP_FILE}

# Keep only last 30 days of backups
mc find ceph-rgw/database-backups --older-than 30d --exec "mc rm {}"
```

### Performance Tuning

```bash
# Use multiple parallel connections for large files
mc cp --parallel 10 large-file.tar.gz ceph-rgw/my-bucket/

# Limit bandwidth
mc cp --limit-upload 10MB large-file.tar.gz ceph-rgw/my-bucket/

# Disable multipart for small files (< 5MB)
mc cp --disable-multipart small-file.txt ceph-rgw/my-bucket/
```

### Integration with Scripts

**Python Example:**

```python
#!/usr/bin/env python3
import subprocess
import json

def mc_command(args):
    """Run mc command and return output"""
    result = subprocess.run(['mc'] + args, capture_output=True, text=True)
    return result.stdout.strip()

# List buckets
buckets = mc_command(['ls', 'ceph-rgw']).split('\n')
for bucket in buckets:
    print(f"Bucket: {bucket}")

# Upload file
mc_command(['cp', 'myfile.txt', 'ceph-rgw/my-bucket/'])

# Get bucket size
size = mc_command(['du', 'ceph-rgw/my-bucket'])
print(f"Bucket size: {size}")
```

**Bash Example:**

```bash
#!/bin/bash
# Automated backup script with mc

# Configuration
SOURCE_DIR="/data/to/backup"
BUCKET="ceph-rgw/backups"
RETENTION_DAYS=90

# Perform backup
echo "Starting backup at $(date)"
mc mirror --remove "${SOURCE_DIR}" "${BUCKET}"

# Cleanup old backups
echo "Cleaning up backups older than ${RETENTION_DAYS} days"
mc find "${BUCKET}" --older-than "${RETENTION_DAYS}d" --exec "mc rm {}"

# Send notification
mc admin info ceph-rgw | mail -s "Backup completed" admin@example.com
```

## Using AWS CLI

If AWS CLI is preferred over MinIO client:

```bash
# Configure AWS CLI
aws configure set aws_access_key_id <AccessKey>
aws configure set aws_secret_access_key <SecretKey>

# Set endpoint
export AWS_ENDPOINT_URL="http://192.168.0.204"

# Create bucket
aws s3 mb s3://my-bucket

# Upload file
aws s3 cp file.txt s3://my-bucket/

# List buckets
aws s3 ls

# Download file
aws s3 cp s3://my-bucket/file.txt ./
```

## Monitoring

### ArgoCD Application Status

```bash
# Check sync status
devbox run -- argocd app get ceph-object-storage
```

### Ceph Pools

```bash
# List RGW pools
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph osd pool ls | grep rgw

# Check pool usage
kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph df
```

### Prometheus Metrics

Access via Grafana: https://grafana.verticon.com

Key metrics:
- `ceph_rgw_req` - Request count
- `ceph_rgw_req_latency_sum` - Request latency
- `ceph_rgw_bandwidth` - Bandwidth usage

## Troubleshooting

### RGW Pods Not Starting

```bash
# Check ArgoCD app status
devbox run -- argocd app get ceph-object-storage

# Check pod events
kubectl describe pod -n rook-ceph -l app=rook-ceph-rgw

# Check Rook operator logs
kubectl logs -n rook-ceph -l app=rook-ceph-operator --tail=100
```

### MinIO Client Connection Issues

```bash
# Test endpoint connectivity
curl http://192.168.0.204

# Verify credentials are correct
kubectl get secret postgresql-backup-user -n rook-ceph -o yaml

# Check mc configuration
mc config host ls

# Test with verbose output
mc --debug ls ceph-rgw

# Re-add alias if corrupted
mc alias remove ceph-rgw
mc alias set ceph-rgw http://192.168.0.204 $ACCESS_KEY $SECRET_KEY
```

### External IP Not Assigned

```bash
# Check MetalLB
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l app=metallb

# Check if IP is already in use
kubectl get svc -A | grep 192.168.0.204
```

## DNS Configuration (Optional)

Add DNS records (via PiHole or router):

```
rgw.verticon.com  A  192.168.0.204
s3.verticon.com   A  192.168.0.204
```

Then configure MinIO client with DNS:

```bash
mc alias set ceph-rgw http://rgw.verticon.com $ACCESS_KEY $SECRET_KEY
```

## Scaling Future Growth

To add more drives later (e.g., /dev/sdd):

1. Install drives on nodes
2. Update CephCluster (see `rook-ceph/cluster/`)
3. Rook automatically creates new OSDs
4. Ceph rebalances data
5. Usable capacity increases automatically

Example: Add 4 more drives → 32TB raw = ~16TB usable (double capacity!)

## Related Documentation

- [Design Document](../../docs/object-storage-design.md) - Architecture decisions
- [Issue #11](https://github.com/jconlon/ops-microk8s/issues/11) - Implementation tracking
- [Rook Object Storage Docs](https://rook.io/docs/rook/latest/Storage-Configuration/Object-Storage-RGW/object-storage/)
- [MinIO Client Documentation](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [Ceph RGW S3 API](https://docs.ceph.com/en/latest/radosgw/s3/)

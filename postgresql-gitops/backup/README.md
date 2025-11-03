# PostgreSQL Backup Configuration

This directory contains the configuration for automated PostgreSQL backups using CloudNativePG and AWS S3.

## Overview

- **Backup Method**: Barman with AWS S3 object storage
- **Schedule**: Daily at 2 AM
- **Retention**: 7 days
- **Compression**: gzip for both WAL and data
- **Target**: Primary instance

## Prerequisites

1. **AWS S3 Bucket**: Create an S3 bucket for PostgreSQL backups
2. **AWS IAM User**: Create an IAM user with S3 access permissions
3. **AWS Credentials**: Obtain Access Key ID and Secret Access Key

### Required AWS IAM Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": ["arn:aws:s3:::postgresql-microk8s-one"]
    }
  ]
}
```

## Setup Steps

### 1. Configure AWS Credentials

Edit `aws-credentials-secret.yaml` and replace the placeholder values:

```yaml
stringData:
  ACCESS_KEY_ID: "your-aws-access-key-id"
  ACCESS_SECRET_KEY: "your-aws-secret-access-key"
```

**Important**: Do not commit this file with real credentials to git!

Apply the secret:

```bash
kubectl apply -f postgresql-gitops/backup/aws-credentials-secret.yaml
```

### 2. Configure S3 Bucket

Edit `production-postgresql-cluster.yaml` and update the S3 bucket name:

```yaml
backup:
  barmanObjectStore:
    destinationPath: "s3://your-bucket-name/postgresql-backups/production/"
```

### 3. Apply Cluster Configuration

Apply the updated cluster configuration:

```bash
kubectl apply -f postgresql-gitops/cluster/production-postgresql-cluster.yaml
```

Wait for the cluster to reconcile and start WAL archiving.

### 4. Create Scheduled Backup

Apply the ScheduledBackup resource:

```bash
kubectl apply -f postgresql-gitops/backup/scheduled-backup.yaml
```

This will trigger an immediate backup for testing and schedule daily backups at 2 AM.

## Verification

### Check Backup Status

```bash
# List all backups
kubectl get backups -n postgresql-system

# Check specific backup details
kubectl describe backup <backup-name> -n postgresql-system

# Check ScheduledBackup status
kubectl get scheduledbackup production-postgresql-daily-backup -n postgresql-system
```

### Check Backup Logs

```bash
# View backup job logs
kubectl logs -n postgresql-system -l job-name=<backup-job-name>
```

### Verify S3 Contents

```bash
# List backups in S3
aws s3 ls s3://your-bucket-name/postgresql-backups/production/

# Check base backups
aws s3 ls s3://your-bucket-name/postgresql-backups/production/base/

# Check WAL archives
aws s3 ls s3://your-bucket-name/postgresql-backups/production/wals/
```

## Restore Procedures

### Restore to Kubernetes Cluster

Create a new cluster from a backup:

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
    size: 100Gi
    storageClassName: mayastor-postgresql-ha
  externalClusters:
    - name: production-postgresql-backup
      barmanObjectStore:
        destinationPath: "s3://your-bucket-name/postgresql-backups/production/"
        s3Credentials:
          accessKeyId:
            name: aws-s3-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: aws-s3-credentials
            key: ACCESS_SECRET_KEY
```

### Restore to Local PostgreSQL

1. **Install Barman CLI** on your local machine:

```bash
sudo apt install barman-cli
```

2. **Set AWS credentials**:

```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
```

3. **List available backups**:

```bash
barman-cloud-backup-list \
  s3://your-bucket-name/postgresql-backups/production/ \
  production-postgresql
```

4. **Restore a specific backup**:

```bash
# Stop local PostgreSQL if running
sudo systemctl stop postgresql

# Remove existing data directory
sudo rm -rf /var/lib/postgresql/17/main/*

# Restore backup
sudo -u postgres barman-cloud-restore \
  s3://your-bucket-name/postgresql-backups/production/ \
  production-postgresql \
  <backup-id> \
  /var/lib/postgresql/17/main

# Start PostgreSQL
sudo systemctl start postgresql
```

5. **Point-in-Time Recovery (optional)**:

Create a recovery configuration file:

```bash
sudo -u postgres cat > /var/lib/postgresql/17/main/recovery.conf <<EOF
restore_command = 'barman-cloud-wal-restore s3://your-bucket-name/postgresql-backups/production/ production-postgresql %f %p'
recovery_target_time = '2025-11-03 12:00:00'
EOF
```

## Monitoring

Add backup metrics to Grafana:

- Backup success/failure rates
- Backup duration
- Backup size
- WAL archiving lag
- S3 storage usage

## Troubleshooting

### Backup Fails with S3 Access Denied

- Verify AWS credentials are correct
- Check IAM policy has required S3 permissions
- Verify S3 bucket exists and is accessible

### WAL Archiving Not Working

```bash
# Check cluster status
kubectl describe cluster production-postgresql -n postgresql-system

# Check pod logs
kubectl logs -n postgresql-system production-postgresql-1 -c postgres
```

### Restore Fails

- Verify backup exists in S3
- Check AWS credentials are valid
- Ensure PostgreSQL version matches (17.5)
- Check disk space on target system

## Files

- `aws-credentials-secret.yaml`: AWS S3 credentials (DO NOT COMMIT WITH REAL VALUES)
- `postgresql-backup-pvc.yaml`: Local PVC for backup cache (optional)
- `scheduled-backup.yaml`: Daily backup schedule configuration
- `../cluster/production-postgresql-cluster.yaml`: Cluster with backup configuration

## Security Notes

1. **Never commit AWS credentials** to git
2. Use **AWS Secrets Manager** or **External Secrets Operator** for production
3. Enable **S3 bucket encryption** at rest
4. Use **S3 bucket versioning** for additional protection
5. Implement **S3 lifecycle policies** to manage backup retention
6. Consider **cross-region replication** for disaster recovery

## References

- [CloudNativePG Backup Documentation](https://cloudnative-pg.io/documentation/current/backup/)
- [Barman Documentation](https://pgbarman.org/)
- [AWS S3 Documentation](https://docs.aws.amazon.com/s3/)

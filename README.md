# PostgreSQL Backup to S3

Automated PostgreSQL database backup solution with S3 storage and IRSA support for EKS.

## Features

- ✅ **Multiple database support** - Backup multiple databases in one job
- ✅ **IRSA authentication** - No AWS credentials in secrets (uses IAM Roles for Service Accounts)
- ✅ **Automatic retention** - Cleanup backups older than specified days
- ✅ **Compressed backups** - Uses gzip compression
- ✅ **EKS optimized** - Designed for Kubernetes/EKS environments
- ✅ **Company base image** - Built on NVisionX Alpine base

## Quick Start

### Kubernetes Deployment

```bash
# Deploy the CronJob
kubectl apply -f kubernetes/cronjob.yaml

# Test immediately
kubectl apply -f kubernetes/test-job.yaml
kubectl logs -f job/postgres-backup-test
```

### Environment Variables

Required:
- `POSTGRES_HOST` - PostgreSQL server hostname
- `POSTGRES_USER` - PostgreSQL username
- `POSTGRES_PASSWORD` - PostgreSQL password
- `DATABASES` - Comma-separated list of databases (e.g., "db1,db2,db3")
- `S3_BUCKET` - S3 bucket name for backups
- `AWS_DEFAULT_REGION` - AWS region

Optional:
- `POSTGRES_PORT` - PostgreSQL port (default: 5432)
- `S3_PREFIX` - S3 prefix/folder (default: postgres-backups)
- `RETENTION_DAYS` - Backup retention in days (default: 30)
- `AWS_WEB_IDENTITY_TOKEN_FILE` - For IRSA (auto-set by EKS)
- `AWS_ROLE_ARN` - IAM role ARN (auto-set by EKS)

## Building

### Using GitHub Actions (Recommended)

Merge to `main` or `master` branch to trigger automatic build.

### Local Build

```bash
# Login to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u your-username --password-stdin

# Build
./build.sh

# Or manually
docker build -t ghcr.io/nvision-x/postgres-backup:latest .
docker push ghcr.io/nvision-x/postgres-backup:latest
```

## Image

**Registry:** `ghcr.io/nvision-x/postgres-backup`

**Tags:**
- `latest` - Latest build from main branch
- `sha-XXXXXXX` - Specific commit SHA
- `vX.Y.Z` - Semantic versioning (when tagged)

**Base Image:** `ghcr.io/nvision-x/alpine-base-dockerfile`

## IAM Setup

### Required S3 Permissions

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject",
                "s3:GetObject",
                "s3:ListBucket",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::your-backup-bucket",
                "arn:aws:s3:::your-backup-bucket/*"
            ]
        }
    ]
}
```

### IRSA Trust Policy

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/XXXXX"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.REGION.amazonaws.com/id/XXXXX:sub": "system:serviceaccount:NAMESPACE:SERVICE_ACCOUNT_NAME",
                    "oidc.eks.REGION.amazonaws.com/id/XXXXX:aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
```

## Backup Schedule

Default schedule: Daily at 2 AM UTC (`0 2 * * *`)

Modify in `kubernetes/cronjob.yaml`:
```yaml
spec:
  schedule: "0 2 * * *"  # Cron format
```

## Monitoring

```bash
# Check CronJob status
kubectl get cronjob postgres-backup

# View recent job logs
kubectl logs job/$(kubectl get jobs -l app=postgres-backup --sort-by=.metadata.creationTimestamp -o name | tail -1)

# List S3 backups
aws s3 ls s3://your-bucket/postgres-backups/ --recursive
```

## Troubleshooting

### Authentication Errors

Check IAM role trust policy includes your service account.

### Database Connection Failed

Verify:
- PostgreSQL host and port
- Username and password
- Network connectivity from EKS to RDS

### S3 Upload Failed

Verify:
- S3 bucket exists
- IAM role has proper permissions
- Bucket policy allows the role

## License

Internal NVisionX tool - Not for external distribution
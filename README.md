# PostgreSQL Backup - Simple Approach

## 📦 What This Is

**Super simple** PostgreSQL backup solution:
- ✅ **One Docker image** with everything baked in
- ✅ **Simple YAML files** - no ConfigMaps with scripts
- ✅ **No Helm** - just plain Kubernetes YAML
- ✅ **Self-contained** - script embedded in the Docker image

## 🏗️ Structure

```
.
├── Dockerfile              # Image with backup script built-in
├── build.sh                # Build the Docker image
├── kubernetes/
│   ├── cronjob.yaml       # Scheduled backup (daily)
│   └── job-test.yaml      # One-time test job
└── README.md              # This file
```

## 🚀 Quick Start

### 1. Build the Docker Image

```bash
# Build
./build.sh your-registry postgres-backup 1.0.0

# Example for GitHub Container Registry
./build.sh ghcr.io/your-org postgres-backup 1.0.0

# Example for AWS ECR
./build.sh 123456.dkr.ecr.us-east-1.amazonaws.com postgres-backup 1.0.0

# Push to registry
docker push your-registry/postgres-backup:1.0.0
```

### 2. Edit Kubernetes YAML Files

**Edit `kubernetes/cronjob.yaml` and `kubernetes/job-test.yaml`:**

```yaml
# Change these values:
- image: your-registry/postgres-backup:1.0.0  # Your image
- POSTGRES_HOST: "your-database.rds.amazonaws.com"
- DATABASES: "db1,db2,db3"  # Comma-separated
- S3_BUCKET: "your-backup-bucket"
- POSTGRES_PASSWORD in Secret
- IAM role ARN in ServiceAccount annotation
```

### 3. Deploy

```bash
# Deploy
kubectl apply -f kubernetes/cronjob.yaml

# Verify
kubectl get cronjob postgres-backup
kubectl get serviceaccount postgres-backup
kubectl get secret postgres-backup-secret
```

### 4. Test Immediately

```bash
# Run test job
kubectl apply -f kubernetes/job-test.yaml

# Watch
kubectl get jobs -w

# Check logs
kubectl logs -l job=test --follow
```

## 📝 Configuration

### Environment Variables (in YAML)

| Variable | Description | Example |
|----------|-------------|---------|
| `POSTGRES_HOST` | Database host | `db.example.com` |
| `POSTGRES_PORT` | Database port | `5432` |
| `POSTGRES_USER` | Database user | `postgres` |
| `POSTGRES_PASSWORD` | Database password | `secret` (from Secret) |
| `DATABASES` | Comma-separated databases | `db1,db2,db3` |
| `S3_BUCKET` | S3 bucket name | `my-backups` |
| `S3_PREFIX` | S3 prefix/folder | `postgres-backups` |
| `AWS_DEFAULT_REGION` | AWS region | `us-east-1` |
| `RETENTION_DAYS` | Days to keep backups | `30` |

### Schedule (Cron Format)

Edit `schedule` in `cronjob.yaml`:

```yaml
schedule: "0 2 * * *"  # Daily at 2 AM UTC
# Other examples:
# "0 */6 * * *"   # Every 6 hours
# "0 0 * * 0"     # Weekly on Sunday
# "0 3 * * 1-5"   # Weekdays at 3 AM
```

## 🔐 AWS Setup

### IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:DeleteObject"
    ],
    "Resource": [
      "arn:aws:s3:::your-bucket",
      "arn:aws:s3:::your-bucket/*"
    ]
  }]
}
```

### IAM Role (IRSA)

```bash
# Create trust policy
cat > trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::ACCOUNT:oidc-provider/oidc.eks.REGION.amazonaws.com/id/OIDC_ID"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.REGION.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:default:postgres-backup"
      }
    }
  }]
}
EOF

# Create role
aws iam create-role --role-name postgres-backup-role \
  --assume-role-policy-document file://trust-policy.json

# Attach policy
aws iam put-role-policy --role-name postgres-backup-role \
  --policy-name s3-access --policy-document file://s3-policy.json
```

## 🎯 Common Commands

```bash
# Manual backup
kubectl create job manual-backup-$(date +%s) --from=cronjob/postgres-backup

# View logs
kubectl logs -l app=postgres-backup --tail=100

# Check job status
kubectl get jobs -l app=postgres-backup

# Suspend backups
kubectl patch cronjob postgres-backup -p '{"spec":{"suspend":true}}'

# Resume backups
kubectl patch cronjob postgres-backup -p '{"spec":{"suspend":false}}'

# Delete everything
kubectl delete -f kubernetes/cronjob.yaml
```

## 🧪 Testing Locally

```bash
# Test with Docker (requires AWS credentials)
docker run --rm \
  -e POSTGRES_HOST=your-host \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=password \
  -e DATABASES=db1,db2 \
  -e S3_BUCKET=your-bucket \
  -e AWS_DEFAULT_REGION=us-east-1 \
  -e AWS_ACCESS_KEY_ID=xxx \
  -e AWS_SECRET_ACCESS_KEY=xxx \
  your-registry/postgres-backup:latest
```

## 📊 How It Works

1. **Docker image** has backup script built-in at `/usr/local/bin/postgres-backup.sh`
2. **When container starts**, script runs automatically
3. **Script does**:
   - Verifies environment variables
   - Tests AWS credentials
   - Tests database connection
   - Backs up each database using `pg_dump`
   - Compresses with `gzip`
   - Uploads to S3
   - Deletes old backups based on retention
4. **Exit codes**: 0 = success, 1 = failure

## 🔄 Updates

To update the image:

```bash
# Modify Dockerfile
vim Dockerfile

# Rebuild with new tag
./build.sh your-registry postgres-backup 1.0.1

# Push
docker push your-registry/postgres-backup:1.0.1

# Update YAML
sed -i 's/:1.0.0/:1.0.1/g' kubernetes/*.yaml

# Apply
kubectl apply -f kubernetes/cronjob.yaml
```

## 🐛 Troubleshooting

**Problem: Image pull error**
```bash
# Verify image exists
docker images | grep postgres-backup

# Check imagePullSecrets if using private registry
kubectl get serviceaccount postgres-backup -o yaml
```

**Problem: AWS credentials failed**
```bash
# Check IRSA annotation
kubectl get sa postgres-backup -o yaml | grep role-arn

# Test in pod
kubectl run test --rm -it --image=amazon/aws-cli \
  --serviceaccount=postgres-backup -- sts get-caller-identity
```

**Problem: Database connection failed**
```bash
# Test from pod
kubectl run test --rm -it --image=postgres:17-alpine -- \
  psql -h your-host -U postgres -d postgres
```

**Problem: Job keeps failing**
```bash
# Check logs
kubectl logs -l app=postgres-backup --tail=100

# Describe job
kubectl describe job postgres-backup-test

# Check events
kubectl get events --sort-by='.lastTimestamp'
```

## ✅ Advantages of This Approach

- ✅ **Simple** - No Helm, no complex templating
- ✅ **Self-contained** - Script is in the image
- ✅ **Easy to version control** - Just track Dockerfile and YAML
- ✅ **Easy to customize** - Edit Dockerfile, rebuild
- ✅ **No external dependencies** - Everything in one image
- ✅ **Works anywhere** - Any Kubernetes cluster

## 📁 For GitHub Repo

Recommended structure:

```
postgres-backup/
├── README.md
├── Dockerfile
├── build.sh
├── .github/
│   └── workflows/
│       └── build.yaml    # GitHub Actions to build image
└── kubernetes/
    ├── cronjob.yaml
    └── job-test.yaml
```

That's it! Simple and clean. 🎉

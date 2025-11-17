FROM postgres:17-alpine

# Install required tools
RUN apk add --no-cache \
    python3 \
    py3-pip \
    bash \
    gzip \
    aws-cli \
    ca-certificates

# Create backup script directly in the image
RUN cat > /usr/local/bin/postgres-backup.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

echo "==========================================="
echo "PostgreSQL Backup to S3"
echo "==========================================="
echo "Started at: $(date)"
echo ""

# Check required environment variables
for var in POSTGRES_HOST POSTGRES_USER POSTGRES_PASSWORD DATABASES S3_BUCKET AWS_DEFAULT_REGION; do
    if [ -z "${!var:-}" ]; then
        echo "❌ ERROR: $var is not set"
        exit 1
    fi
done

# Set defaults
POSTGRES_PORT=${POSTGRES_PORT:-5432}
S3_PREFIX=${S3_PREFIX:-postgres-backups}
RETENTION_DAYS=${RETENTION_DAYS:-30}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/backups"

mkdir -p ${BACKUP_DIR}

# Parse databases (comma-separated)
IFS=',' read -ra DB_ARRAY <<< "${DATABASES}"

echo "Configuration:"
echo "  Host: ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "  Databases: ${DATABASES}"
echo "  S3: s3://${S3_BUCKET}/${S3_PREFIX}"
echo "  Retention: ${RETENTION_DAYS} days"
echo ""

# Verify AWS credentials
echo "Verifying AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "❌ AWS credentials verification failed"
    exit 1
fi
echo "✅ AWS credentials OK"
echo ""

# Test database connection
echo "Testing database connection..."
if ! PGPASSWORD=${POSTGRES_PASSWORD} psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d postgres -c "SELECT 1;" > /dev/null 2>&1; then
    echo "❌ Database connection failed"
    exit 1
fi
echo "✅ Database connection OK"
echo ""

# Backup each database
SUCCESS=0
FAILED=0

for DB in "${DB_ARRAY[@]}"; do
    echo "==========================================="
    echo "📦 Backing up: ${DB}"
    DUMP_FILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    
    if PGPASSWORD=${POSTGRES_PASSWORD} pg_dump \
        -h ${POSTGRES_HOST} \
        -p ${POSTGRES_PORT} \
        -U ${POSTGRES_USER} \
        -d ${DB} \
        --no-owner \
        --no-acl \
        --clean \
        --if-exists 2>&1 | gzip > ${DUMP_FILE}; then
        
        SIZE=$(du -h ${DUMP_FILE} | cut -f1)
        echo "✅ Backup created: ${SIZE}"
        
        # Upload to S3
        S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/${DB}_${TIMESTAMP}.sql.gz"
        echo "☁️  Uploading to S3..."
        
        if aws s3 cp ${DUMP_FILE} ${S3_PATH} --region ${AWS_DEFAULT_REGION}; then
            echo "✅ Uploaded to: ${S3_PATH}"
            rm -f ${DUMP_FILE}
            ((SUCCESS++))
        else
            echo "❌ Upload failed"
            ((FAILED++))
        fi
    else
        echo "❌ Backup failed"
        ((FAILED++))
    fi
    echo ""
done

# Cleanup old backups
echo "==========================================="
echo "🧹 Cleaning up old backups..."
CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d 2>/dev/null || date -v-${RETENTION_DAYS}d +%Y%m%d)
DELETED=0

for DB in "${DB_ARRAY[@]}"; do
    aws s3 ls s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/ --region ${AWS_DEFAULT_REGION} 2>/dev/null | while read -r line; do
        FILE=$(echo $line | awk '{print $4}')
        if [[ $FILE =~ ${DB}_([0-9]{8})_[0-9]{6}\.sql\.gz$ ]]; then
            FILE_DATE=${BASH_REMATCH[1]}
            if [[ $FILE_DATE < $CUTOFF_DATE ]]; then
                echo "🗑️  Deleting: ${FILE}"
                aws s3 rm s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/${FILE} --region ${AWS_DEFAULT_REGION}
                ((DELETED++))
            fi
        fi
    done
done

echo "Deleted ${DELETED} old backup(s)"
echo ""

# Summary
echo "==========================================="
echo "Backup Summary:"
echo "  Successful: ${SUCCESS}"
echo "  Failed: ${FAILED}"
echo "  Completed at: $(date)"
echo "==========================================="

if [ ${FAILED} -eq 0 ]; then
    echo "✅ All backups completed successfully"
    exit 0
else
    echo "❌ Some backups failed"
    exit 1
fi
SCRIPT

# Make script executable
RUN chmod +x /usr/local/bin/postgres-backup.sh

# Set working directory
WORKDIR /tmp

# Default command
CMD ["/usr/local/bin/postgres-backup.sh"]

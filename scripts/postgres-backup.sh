#!/bin/bash
# PostgreSQL Backup Script for S3
# Security-hardened backup script for PostgreSQL databases
# Supports IRSA authentication and multi-database backups

set -euo pipefail

# Enable bash strict mode
IFS=$'\n\t'

echo "==========================================="
echo "PostgreSQL Backup to S3"
echo "==========================================="
echo "Started at: $(date)"
echo ""

# Function to log errors
log_error() {
    echo "❌ ERROR: $1" >&2
}

# Function to log success
log_success() {
    echo "✅ $1"
}

# Function to log info
log_info() {
    echo "ℹ️  $1"
}

# Check required environment variables
REQUIRED_VARS=(
    "POSTGRES_HOST"
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "DATABASES"
    "S3_BUCKET"
    "AWS_DEFAULT_REGION"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        MISSING_VARS+=("$var")
    fi
done

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    log_error "Required environment variables not set: ${MISSING_VARS[*]}"
    exit 1
fi

# Set defaults for optional variables
POSTGRES_PORT=${POSTGRES_PORT:-5432}
S3_PREFIX=${S3_PREFIX:-postgres-backups}
RETENTION_DAYS=${RETENTION_DAYS:-30}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/tmp/backups"

# Validate numeric values
if ! [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]]; then
    log_error "POSTGRES_PORT must be a number"
    exit 1
fi

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    log_error "RETENTION_DAYS must be a number"
    exit 1
fi

# Create backup directory with secure permissions
mkdir -p "${BACKUP_DIR}"
chmod 750 "${BACKUP_DIR}"

# Parse databases (comma-separated, trim whitespace)
IFS=',' read -ra DB_ARRAY <<< "${DATABASES}"
# Trim whitespace from each database name
for i in "${!DB_ARRAY[@]}"; do
    DB_ARRAY[$i]=$(echo "${DB_ARRAY[$i]}" | xargs)
done

# Validate database names (alphanumeric, underscore, hyphen only)
for DB in "${DB_ARRAY[@]}"; do
    if ! [[ "$DB" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid database name: $DB (only alphanumeric, underscore, and hyphen allowed)"
        exit 1
    fi
done

echo "Configuration:"
echo "  Host: ${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "  User: ${POSTGRES_USER}"
echo "  Databases: ${DATABASES}"
echo "  S3 Bucket: s3://${S3_BUCKET}/${S3_PREFIX}"
echo "  Region: ${AWS_DEFAULT_REGION}"
echo "  Retention: ${RETENTION_DAYS} days"
echo "  Running as: $(whoami)"
echo ""

# Verify AWS credentials (IRSA-aware)
log_info "Verifying AWS credentials..."
if [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] && [ -f "${AWS_WEB_IDENTITY_TOKEN_FILE}" ]; then
    log_success "Using IRSA (IAM Roles for Service Accounts)"
    log_info "Token file: ${AWS_WEB_IDENTITY_TOKEN_FILE}"
    log_info "Role ARN: ${AWS_ROLE_ARN:-not set}"
    
    # Try to verify credentials
    if aws sts get-caller-identity --region "${AWS_DEFAULT_REGION}" > /dev/null 2>&1; then
        CALLER_ID=$(aws sts get-caller-identity --region "${AWS_DEFAULT_REGION}" --output json 2>/dev/null || echo "{}")
        log_success "AWS credentials verified"
        echo "   Account: $(echo "$CALLER_ID" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)"
        echo "   ARN: $(echo "$CALLER_ID" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)"
    else
        log_info "AWS credentials not verified yet, will attempt backup anyway"
    fi
elif aws sts get-caller-identity --region "${AWS_DEFAULT_REGION}" > /dev/null 2>&1; then
    log_success "Using AWS credentials from environment"
else
    log_error "No valid AWS credentials found"
    exit 1
fi
echo ""

# Test S3 bucket access
log_info "Testing S3 bucket access..."
if aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --region "${AWS_DEFAULT_REGION}" > /dev/null 2>&1; then
    log_success "S3 bucket accessible"
else
    log_error "Cannot access S3 bucket: s3://${S3_BUCKET}/${S3_PREFIX}/"
    exit 1
fi
echo ""

# Test database connection
log_info "Testing database connection..."
export PGPASSWORD="${POSTGRES_PASSWORD}"

if timeout 10 psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d postgres -c "SELECT version();" > /dev/null 2>&1; then
    DB_VERSION=$(psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d postgres -t -c "SELECT version();" 2>/dev/null | xargs)
    log_success "Database connection OK"
    log_info "PostgreSQL version: ${DB_VERSION}"
else
    log_error "Database connection failed"
    exit 1
fi
echo ""

# Backup each database
SUCCESS=0
FAILED=0
TOTAL_SIZE=0

for DB in "${DB_ARRAY[@]}"; do
    echo "==========================================="
    echo "📦 Backing up database: ${DB}"
    echo "-------------------------------------------"
    
    DUMP_FILE="${BACKUP_DIR}/${DB}_${TIMESTAMP}.sql.gz"
    
    # Verify database exists
    if ! psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" -U "${POSTGRES_USER}" -d postgres -lqt | cut -d \| -f 1 | grep -qw "${DB}"; then
        log_error "Database '${DB}' does not exist"
        FAILED=$((FAILED + 1))
        echo ""
        continue
    fi
    
    # Perform backup with timeout
    log_info "Creating backup..."
    if timeout 3600 pg_dump \
        -h "${POSTGRES_HOST}" \
        -p "${POSTGRES_PORT}" \
        -U "${POSTGRES_USER}" \
        -d "${DB}" \
        --no-owner \
        --no-acl \
        --clean \
        --if-exists \
        --verbose 2>&1 | gzip > "${DUMP_FILE}"; then
        
        # Verify backup file was created and is not empty
        if [ -f "${DUMP_FILE}" ] && [ -s "${DUMP_FILE}" ]; then
            SIZE=$(du -h "${DUMP_FILE}" | cut -f1)
            SIZE_BYTES=$(stat -f%z "${DUMP_FILE}" 2>/dev/null || stat -c%s "${DUMP_FILE}" 2>/dev/null)
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE_BYTES))
            log_success "Backup created: ${SIZE}"
            
            # Upload to S3 with retry logic
            S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/${DB}_${TIMESTAMP}.sql.gz"
            log_info "Uploading to S3..."
            
            UPLOAD_SUCCESS=false
            for attempt in {1..3}; do
                if aws s3 cp "${DUMP_FILE}" "${S3_PATH}" \
                    --region "${AWS_DEFAULT_REGION}" \
                    --storage-class STANDARD_IA \
                    --metadata "database=${DB},timestamp=${TIMESTAMP},backup-host=${POSTGRES_HOST}"; then
                    log_success "Uploaded to: ${S3_PATH}"
                    UPLOAD_SUCCESS=true
                    break
                else
                    if [ $attempt -lt 3 ]; then
                        log_info "Upload attempt $attempt failed, retrying..."
                        sleep 5
                    fi
                fi
            done
            
            if [ "$UPLOAD_SUCCESS" = true ]; then
                # Securely remove local backup file
                shred -u -z -n 1 "${DUMP_FILE}" 2>/dev/null || rm -f "${DUMP_FILE}"
                SUCCESS=$((SUCCESS + 1))
            else
                log_error "Upload failed after 3 attempts"
                rm -f "${DUMP_FILE}"
                FAILED=$((FAILED + 1))
            fi
        else
            log_error "Backup file is empty or doesn't exist"
            rm -f "${DUMP_FILE}"
            FAILED=$((FAILED + 1))
        fi
    else
        log_error "Backup failed"
        rm -f "${DUMP_FILE}"
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

# Cleanup old backups
echo "==========================================="
echo "🧹 Cleaning up old backups..."
echo "-------------------------------------------"
CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d 2>/dev/null || date -v-${RETENTION_DAYS}d +%Y%m%d)
DELETED=0

for DB in "${DB_ARRAY[@]}"; do
    log_info "Checking old backups for database: ${DB}"
    
    # List and process old backups
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/" --region "${AWS_DEFAULT_REGION}" 2>/dev/null | while read -r line; do
        FILE=$(echo "$line" | awk '{print $4}')
        
        # Extract date from filename (format: dbname_YYYYMMDD_HHMMSS.sql.gz)
        if [[ $FILE =~ ${DB}_([0-9]{8})_[0-9]{6}\.sql\.gz$ ]]; then
            FILE_DATE=${BASH_REMATCH[1]}
            
            if [[ $FILE_DATE < $CUTOFF_DATE ]]; then
                log_info "Deleting old backup: ${FILE} (${FILE_DATE})"
                if aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${DB}/${FILE}" --region "${AWS_DEFAULT_REGION}"; then
                    DELETED=$((DELETED + 1))
                fi
            fi
        fi
    done
done

echo ""
log_success "Deleted ${DELETED} old backup(s)"
echo ""

# Final summary
echo "==========================================="
echo "📊 Backup Summary"
echo "==========================================="
echo "  Total Databases: ${#DB_ARRAY[@]}"
echo "  Successful: ${SUCCESS}"
echo "  Failed: ${FAILED}"
if [ ${SUCCESS} -gt 0 ]; then
    TOTAL_SIZE_MB=$((TOTAL_SIZE / 1024 / 1024))
    echo "  Total Size: ${TOTAL_SIZE_MB} MB"
fi
echo "  Completed at: $(date)"
echo "==========================================="
echo ""

# Exit with appropriate status
if [ ${FAILED} -eq 0 ]; then
    log_success "All backups completed successfully! 🎉"
    exit 0
else
    log_error "Some backups failed (${FAILED}/${#DB_ARRAY[@]})"
    exit 1
fi
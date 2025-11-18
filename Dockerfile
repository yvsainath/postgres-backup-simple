# Hardened PostgreSQL Backup Image
# Based on security-hardened Alpine base image
# Includes comprehensive security scanning and best practices

# Use the hardened Alpine base image from your registry
# Note: Use the actual image digest, not the .sig file
FROM ghcr.io/nvision-x/alpine-base-dockerfile@sha256:e1c87245f926bdc2b2c694f0771f561ed07af4ded7e1037a7af8d8a897d9c9d5

# Build arguments for metadata
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=1.0.0

# Metadata labels following OCI standards
LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.title="Hardened PostgreSQL Backup" \
      org.opencontainers.image.description="Security-hardened PostgreSQL backup container with S3 support" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="NVISIONx" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devops@nvisionx.com"

# Switch to root for installation (required for apk)
USER root

# Install PostgreSQL client and backup tools with security hardening
RUN set -eux; \
    # Update package index
    apk update; \
    \
    # Install required packages (flexible versioning to avoid build failures)
    # Note: Strict version pinning (=~17) can cause "exit code: 3" errors
    # when exact versions don't match available packages
    apk add --no-cache \
        postgresql17-client \
        python3 \
        py3-pip \
        bash \
        gzip \
        coreutils \
        findutils; \
    \
    # Install AWS CLI using pip (let pip resolve compatible versions)
    # Note: Exact versions (==1.36.14) can cause dependency conflicts
    pip3 install --no-cache-dir --break-system-packages \
        awscli \
        botocore; \
    \
    # Clean up package cache
    rm -rf /var/cache/apk/*; \
    rm -rf /root/.cache; \
    \
    # Verify critical binaries exist
    command -v pg_dump || exit 1; \
    command -v psql || exit 1; \
    command -v aws || exit 1; \
    command -v python3 || exit 1; \
    \
    # Create backup working directory with permissive permissions initially
    # Will be secured after switching to appuser
    mkdir -p /tmp/backups; \
    chmod 777 /tmp/backups; \
    \
    # Remove setuid/setgid bits from new binaries
    find /usr -xdev -perm /6000 -type f -exec chmod a-s {} \; 2>/dev/null || true

# Set working directory first
WORKDIR /app

# Copy backup script to working directory with proper permissions
COPY --chown=appuser:appgroup --chmod=755 scripts/postgres-backup.sh /app/postgres-backup.sh

# Verify script was copied correctly
RUN test -f /app/postgres-backup.sh && \
    test -x /app/postgres-backup.sh

# Set secure environment variables
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PYTHONUNBUFFERED=1 \
    # PostgreSQL defaults (override at runtime)
    POSTGRES_PORT=5432 \
    # S3 defaults (override at runtime)
    S3_PREFIX=postgres-backups \
    RETENTION_DAYS=30 \
    # Security: Prevent Python from creating bytecode files
    PYTHONDONTWRITEBYTECODE=1

# Health check to verify script exists and is executable
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/bin/sh", "-c", "test -x /app/postgres-backup.sh && exit 0 || exit 1"]

# Switch to non-root user for runtime
USER appuser

# Secure the backup directory now that we're running as appuser
RUN mkdir -p /tmp/backups && chmod 750 /tmp/backups

# Use dumb-init as entrypoint (inherited from base image)
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Default command runs the backup script from working directory
CMD ["/bin/bash", "/app/postgres-backup.sh"]
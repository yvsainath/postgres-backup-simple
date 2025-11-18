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
    # Install required packages with specific versions where possible
    apk add --no-cache \
        postgresql17-client=~17 \
        python3=~3.12 \
        py3-pip=~24 \
        bash=~5.2 \
        gzip=~1.13 \
        coreutils=~9.5 \
        findutils=~4.10; \
    \
    # Install AWS CLI using pip with break-system-packages flag
    pip3 install --no-cache-dir --break-system-packages \
        awscli==1.36.14 \
        botocore==1.36.14; \
    \
    # Clean up package cache
    rm -rf /var/cache/apk/*; \
    rm -rf /root/.cache; \
    \
    # Create backup script directory with proper permissions
    mkdir -p /usr/local/bin; \
    \
    # Create backup working directory owned by appuser
    mkdir -p /tmp/backups; \
    chown -R appuser:appgroup /tmp/backups; \
    chmod 750 /tmp/backups; \
    \
    # Remove any world-writable permissions
    find /tmp/backups -type d -exec chmod 750 {} \;; \
    find /tmp/backups -type f -exec chmod 640 {} \; 2>/dev/null || true; \
    \
    # Verify critical binaries exist
    command -v pg_dump || exit 1; \
    command -v psql || exit 1; \
    command -v aws || exit 1; \
    command -v python3 || exit 1; \
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

# Create backup directory for temporary files
RUN mkdir -p /tmp/backups && \
    chown -R appuser:appgroup /tmp/backups && \
    chmod 750 /tmp/backups

# Health check to verify script exists and is executable
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/bin/sh", "-c", "test -x /app/postgres-backup.sh && exit 0 || exit 1"]

# Switch to non-root user for runtime
USER appuser

# Use dumb-init as entrypoint (inherited from base image)
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Default command runs the backup script from working directory
CMD ["/bin/bash", "/app/postgres-backup.sh"]
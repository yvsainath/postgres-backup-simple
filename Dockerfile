# Hardened PostgreSQL Backup Image
FROM ghcr.io/nvision-x/alpine-base-dockerfile@sha256:e1c87245f926bdc2b2c694f0771f561ed07af4ded7e1037a7af8d8a897d9c9d5

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=1.0.0

LABEL org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.title="Hardened PostgreSQL Backup" \
      org.opencontainers.image.description="Security-hardened PostgreSQL backup container with S3 support" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="NVISIONx" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="devops@nvisionx.com"

USER root

RUN set -eux; \
    apk update; \
    apk add --no-cache \
        postgresql17-client \
        python3 \
        py3-pip \
        bash \
        gzip \
        coreutils \
        findutils; \
    pip3 install --no-cache-dir --break-system-packages awscli botocore; \
    rm -rf /var/cache/apk/* /root/.cache; \
    command -v pg_dump || exit 1; \
    command -v psql || exit 1; \
    command -v aws || exit 1; \
    command -v python3 || exit 1

WORKDIR /app

COPY --chown=appuser:appgroup --chmod=755 scripts/postgres-backup.sh /app/postgres-backup.sh

RUN test -f /app/postgres-backup.sh && test -x /app/postgres-backup.sh

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    PYTHONUNBUFFERED=1 \
    POSTGRES_PORT=5432 \
    S3_PREFIX=postgres-backups \
    RETENTION_DAYS=30 \
    PYTHONDONTWRITEBYTECODE=1

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD ["/bin/sh", "-c", "test -x /app/postgres-backup.sh && exit 0 || exit 1"]

USER appuser

ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD ["/bin/bash", "/app/postgres-backup.sh"]
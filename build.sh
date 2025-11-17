#!/bin/bash
set -e

# Configuration
REGISTRY="${1:-your-registry}"
IMAGE_NAME="${2:-postgres-backup}"
TAG="${3:-latest}"

FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${TAG}"

echo "=================================="
echo "Building PostgreSQL Backup Image"
echo "=================================="
echo "Image: ${FULL_IMAGE}"
echo ""

# Build
docker build -t ${FULL_IMAGE} .

echo ""
echo "✅ Build complete!"
echo ""
echo "To push:"
echo "  docker push ${FULL_IMAGE}"
echo ""
echo "To test locally:"
echo "  docker run --rm -e POSTGRES_HOST=your-host -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=pass -e DATABASES=db1,db2 -e S3_BUCKET=bucket -e AWS_DEFAULT_REGION=us-east-1 ${FULL_IMAGE}"

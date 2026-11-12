#!/usr/bin/env bash
# ==============================================================================
# CompNova Repository Controls - Immutable AWS S3 Vault Provisioner
# Slide 2: "Immutable Vault - Isolated AWS S3 bucket with Object Lock"
# Slide 3: "Locked Storage - Protected against deletion"
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# GLOBAL VARIABLE: S3 Storage Bucket URL (Easily Editable)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../config/backup.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/backup.env"
fi

S3_BUCKET_URL="${S3_BUCKET_URL:-s3://compnova-git-immutable-vault}"
AWS_REGION="${AWS_REGION:-us-east-1}"
OBJECT_LOCK_MODE="${OBJECT_LOCK_MODE:-COMPLIANCE}"
OBJECT_LOCK_RETENTION_DAYS="${OBJECT_LOCK_RETENTION_DAYS:-90}"

S3_BUCKET_URL="${S3_BUCKET_URL%/}"
BUCKET_NAME="${S3_BUCKET_URL#s3://}"
BUCKET_NAME="${BUCKET_NAME%%/*}"

echo "=================================================================="
echo "[CompNova S3 Immutable Vault Setup]"
echo "Target S3 Bucket URL : ${S3_BUCKET_URL}"
echo "AWS Region           : ${AWS_REGION}"
echo "Object Lock Mode     : ${OBJECT_LOCK_MODE} (${OBJECT_LOCK_RETENTION_DAYS} days)"
echo "=================================================================="

echo "[1/5] Creating isolated S3 bucket with Object Lock enabled..."
if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --object-lock-enabled-for-bucket 2>/dev/null || echo "  -> Bucket '${BUCKET_NAME}' already exists."
else
  aws s3api create-bucket \
    --bucket "${BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}" \
    --object-lock-enabled-for-bucket 2>/dev/null || echo "  -> Bucket '${BUCKET_NAME}' already exists."
fi

echo "[2/5] Blocking all public access on '${BUCKET_NAME}'..."
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "[3/5] Enabling S3 Versioning..."
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

echo "[4/5] Configuring default Server-Side Encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }
    ]
  }'

echo "[5/5] Configuring S3 Object Lock default retention (${OBJECT_LOCK_MODE}, ${OBJECT_LOCK_RETENTION_DAYS} days)..."
aws s3api put-object-lock-configuration \
  --bucket "${BUCKET_NAME}" \
  --object-lock-configuration "{
    \"ObjectLockEnabled\": \"Enabled\",
    \"Rule\": {
      \"DefaultRetention\": {
        \"Mode\": \"${OBJECT_LOCK_MODE}\",
        \"Days\": ${OBJECT_LOCK_RETENTION_DAYS}
      }
    }
  }"

echo "=================================================================="
echo "[CompNova S3 Immutable Vault Setup] COMPLETE"
echo "Vault '${S3_BUCKET_URL}' is isolated, encrypted, and Object-Locked."
echo "=================================================================="

#!/usr/bin/env bash
# ==============================================================================
# CompNova Dual-Path Backup Workflow - PATH A: REAL-TIME (Every Commit)
# 1. Triggered when code push is merged to protected branch
# 2. Bundles full Git history (all branches, tags, and refs)
# 3. Performs instant encrypted upload to S3 Archive with Object Lock support
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
S3_REALTIME_PREFIX="${S3_REALTIME_PREFIX:-path-a-realtime}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSE_ALGORITHM="${SSE_ALGORITHM:-AES256}"
SSE_KMS_KEY_ID="${SSE_KMS_KEY_ID:-}"
ENABLE_OBJECT_LOCK="${ENABLE_OBJECT_LOCK:-true}"
OBJECT_LOCK_MODE="${OBJECT_LOCK_MODE:-COMPLIANCE}"
OBJECT_LOCK_RETENTION_DAYS="${OBJECT_LOCK_RETENTION_DAYS:-90}"

# Normalize S3_BUCKET_URL (strip trailing slash)
S3_BUCKET_URL="${S3_BUCKET_URL%/}"
BUCKET_NAME="${S3_BUCKET_URL#s3://}"
BUCKET_NAME="${BUCKET_NAME%%/*}"

echo "=================================================================="
echo "[Path A: Real-Time Backup] Starting full-history Git bundle backup"
echo "Target S3 Bucket URL: ${S3_BUCKET_URL}"
echo "=================================================================="

# NOTE: no 'git fetch --all --tags --prune' here - the Path A workflow checks
# out full history and all tags (fetch-depth: 0, fetch-tags: true) exactly
# once, so a second full fetch per merge is redundant.
#
# Ref coverage: actions/checkout fetches refs/heads/* and refs/tags/*, but NOT
# refs/notes/* or custom refs. Fetch those explicitly (best effort) so the
# bundle matches Path B's 'git clone --mirror' coverage. 'git bundle create
# --all' packs every ref present locally.
git fetch --force --prune origin '+refs/notes/*:refs/notes/*' 2>/dev/null || true
git fetch --force --prune origin '+refs/pull/*/head:refs/pull/*/head' 2>/dev/null || true
REPO_NAME="${GITHUB_REPOSITORY:-$(basename "$(git rev-parse --show-toplevel)")}"
REPO_SAFE_NAME="${REPO_NAME//\//-}"
BRANCH_NAME="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
COMMIT_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=12 HEAD)"
TIMESTAMP_UTC="$(date -u +"%Y%m%dT%H%M%SZ")"
DATE_PARTITION="$(date -u +"%Y/%m/%d")"

WORK_DIR="$(mktemp -d -t compnova-realtime-backup-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

BUNDLE_FILENAME="${REPO_SAFE_NAME}-${BRANCH_NAME}-${SHORT_SHA}-${TIMESTAMP_UTC}.bundle"
BUNDLE_PATH="${WORK_DIR}/${BUNDLE_FILENAME}"

echo "[1/4] Creating full-history Git bundle: ${BUNDLE_FILENAME}"
git bundle create "${BUNDLE_PATH}" --all

echo "[2/4] Verifying Git bundle integrity..."
git bundle verify "${BUNDLE_PATH}"

UPLOAD_FILE="${BUNDLE_PATH}"
UPLOAD_FILENAME="${BUNDLE_FILENAME}"

# Optional client-side envelope encryption in addition to S3 SSE if passphrase is set
if [[ -n "${BACKUP_ENCRYPTION_PASSPHRASE:-}" ]]; then
  echo "[2b/4] Applying client-side AES-256-CBC encryption before S3 transfer..."
  ENCRYPTED_PATH="${BUNDLE_PATH}.enc"
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
    -in "${BUNDLE_PATH}" \
    -out "${ENCRYPTED_PATH}" \
    -pass env:BACKUP_ENCRYPTION_PASSPHRASE
  UPLOAD_FILE="${ENCRYPTED_PATH}"
  UPLOAD_FILENAME="${BUNDLE_FILENAME}.enc"
fi

SHA256_SUM="$(sha256sum "${UPLOAD_FILE}" | awk '{print $1}')"
SHA256_BASE64="$(openssl dgst -sha256 -binary "${UPLOAD_FILE}" | openssl base64)"
MANIFEST_PATH="${WORK_DIR}/${UPLOAD_FILENAME}.manifest.json"

cat > "${MANIFEST_PATH}" <<EOF
{
  "backup_type": "PATH_A_REALTIME_COMMIT_BUNDLE",
  "repository": "${REPO_NAME}",
  "branch": "${BRANCH_NAME}",
  "commit_sha": "${COMMIT_SHA}",
  "timestamp_utc": "${TIMESTAMP_UTC}",
  "artifact": "${UPLOAD_FILENAME}",
  "sha256": "${SHA256_SUM}",
  "s3_bucket_url": "${S3_BUCKET_URL}",
  "server_side_encryption": "${SSE_ALGORITHM}",
  "object_lock_enabled": "${ENABLE_OBJECT_LOCK}",
  "object_lock_mode": "${OBJECT_LOCK_MODE}"
}
EOF

DEST_S3_URI="${S3_BUCKET_URL}/${S3_REALTIME_PREFIX}/${DATE_PARTITION}/${UPLOAD_FILENAME}"
DEST_MANIFEST_URI="${S3_BUCKET_URL}/${S3_REALTIME_PREFIX}/${DATE_PARTITION}/${UPLOAD_FILENAME}.manifest.json"

SSE_ARGS=(--sse "${SSE_ALGORITHM}")
if [[ "${SSE_ALGORITHM}" == "aws:kms" && -n "${SSE_KMS_KEY_ID}" ]]; then
  SSE_ARGS+=(--sse-kms-key-id "${SSE_KMS_KEY_ID}")
fi

echo "[3/4] Uploading encrypted bundle and manifest to ${DEST_S3_URI}..."
aws s3 cp "${UPLOAD_FILE}" "${DEST_S3_URI}" \
  --region "${AWS_REGION}" \
  "${SSE_ARGS[@]}" \
  --metadata "repository=${REPO_SAFE_NAME},branch=${BRANCH_NAME},commit=${COMMIT_SHA},sha256=${SHA256_SUM}"

aws s3 cp "${MANIFEST_PATH}" "${DEST_MANIFEST_URI}" \
  --region "${AWS_REGION}" \
  "${SSE_ARGS[@]}"

# Apply explicit S3 Object Lock retention if enabled and supported by bucket
if [[ "${ENABLE_OBJECT_LOCK}" == "true" ]]; then
  RETAIN_UNTIL="$(date -u -d "+${OBJECT_LOCK_RETENTION_DAYS} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int('${OBJECT_LOCK_RETENTION_DAYS}'))).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  # Every uploaded object (bundle AND manifest) gets the same explicit
  # retention; otherwise the manifest silently falls back to the bucket default.
  echo "[4/4] Verifying/Applying S3 Object Lock (${OBJECT_LOCK_MODE} until ${RETAIN_UNTIL})..."
  for OBJECT_KEY in "${S3_REALTIME_PREFIX}/${DATE_PARTITION}/${UPLOAD_FILENAME}" "${S3_REALTIME_PREFIX}/${DATE_PARTITION}/${UPLOAD_FILENAME}.manifest.json"; do
    aws s3api put-object-retention \
      --bucket "${BUCKET_NAME}" \
      --key "${OBJECT_KEY}" \
      --retention "Mode=${OBJECT_LOCK_MODE},RetainUntilDate=${RETAIN_UNTIL}" \
      --region "${AWS_REGION}" 2>/dev/null || echo "Note: Relying on bucket-level default Object Lock retention for ${OBJECT_KEY}."
  done
else
  echo "[4/4] Upload complete (explicit per-object retention skipped; using bucket policy)."
fi

echo "=================================================================="
echo "[Path A: Real-Time Backup] SUCCESS"
echo "Uploaded Archive : ${DEST_S3_URI}"
echo "SHA-256 Checksum : ${SHA256_SUM}"
echo "=================================================================="

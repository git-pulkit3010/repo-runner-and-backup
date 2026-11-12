#!/usr/bin/env bash
# ==============================================================================
# CompNova Backup Restore Utility
# Downloads and verifies a Git bundle or bare mirror archive from S3_BUCKET_URL
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

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <s3-object-key-or-full-s3-uri> [target-restore-dir]"
  echo "Example: $0 path-a-realtime/2026/11/12/sap-server-main-abc1234.bundle ./restored-repo"
  exit 1
fi

SOURCE_ARG="$1"
TARGET_DIR="${2:-./restored-repository}"

if [[ "${SOURCE_ARG}" == s3://* ]]; then
  SOURCE_URI="${SOURCE_ARG}"
else
  SOURCE_URI="${S3_BUCKET_URL%/}/${SOURCE_ARG#/}"
fi

WORK_DIR="$(mktemp -d -t compnova-restore-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

FILENAME="$(basename "${SOURCE_URI}")"
LOCAL_FILE="${WORK_DIR}/${FILENAME}"

echo "[1/3] Downloading backup artifact from ${SOURCE_URI}..."
aws s3 cp "${SOURCE_URI}" "${LOCAL_FILE}" --region "${AWS_REGION}"

if [[ "${LOCAL_FILE}" == *.enc ]]; then
  if [[ -z "${BACKUP_ENCRYPTION_PASSPHRASE:-}" ]]; then
    echo "[ERROR] Backup is encrypted (.enc). Set BACKUP_ENCRYPTION_PASSPHRASE to decrypt."
    exit 1
  fi
  DECRYPTED_FILE="${LOCAL_FILE%.enc}"
  echo "[2/3] Decrypting archive..."
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
    -in "${LOCAL_FILE}" \
    -out "${DECRYPTED_FILE}" \
    -pass env:BACKUP_ENCRYPTION_PASSPHRASE
  LOCAL_FILE="${DECRYPTED_FILE}"
fi

echo "[3/3] Restoring repository into ${TARGET_DIR}..."
if [[ "${LOCAL_FILE}" == *.bundle ]]; then
  git bundle verify "${LOCAL_FILE}"
  git clone "${LOCAL_FILE}" "${TARGET_DIR}"
elif [[ "${LOCAL_FILE}" == *.tar.gz ]]; then
  mkdir -p "${TARGET_DIR}"
  tar -xzf "${LOCAL_FILE}" -C "${TARGET_DIR}"
fi

echo "[SUCCESS] Repository restored to ${TARGET_DIR}"

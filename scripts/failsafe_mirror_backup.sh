#!/usr/bin/env bash
# ==============================================================================
# CompNova Dual-Path Backup Workflow - PATH B: FAIL-SAFE (Daily Schedule)
# 1. External Timer: Runs outside repository (via cron/systemd timer or external runner)
#    - NEVER schedule this from an in-repo workflow (failure isolation: the
#      backup must survive deletion of the repository itself).
# 2. Mirror Pull: Clones all branches, tags, notes, and refs (--mirror)
# 3. Locked Storage: Uploads to isolated S3 bucket with Object Lock protection
# 4. Multi-Repo: Mirrors every entry of GITHUB_REPO_LIST under a per-repo S3
#    sub-prefix; one failing repo never blocks the others, but the aggregate
#    exit code stays non-zero so the external timer surfaces the failure.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# GLOBAL VARIABLE: S3 Storage Bucket URL (Easily Editable)
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture caller-provided overrides BEFORE sourcing config/backup.env: the
# in-repo manual-fallback workflow injects GITHUB_REPO_URL (an ephemeral token
# URL) and REPO_NAME per run and must keep priority over the config defaults.
# Ad-hoc/env overrides of the repo list work the same way; config remains the
# source of truth whenever the caller does not set these explicitly.
CALLER_GITHUB_REPO_URL="${GITHUB_REPO_URL:-}"
CALLER_REPO_NAME="${REPO_NAME:-}"
CALLER_GITHUB_REPO_LIST="${GITHUB_REPO_LIST:-}"
CALLER_GITHUB_REPO="${GITHUB_REPO:-}"
CALLER_GIT_AUTH_MODE="${GIT_AUTH_MODE:-}"
CALLER_GIT_SSH_KEY_FILE="${GIT_SSH_KEY_FILE:-}"
CALLER_GIT_SSH_KNOWN_HOSTS_FILE="${GIT_SSH_KNOWN_HOSTS_FILE:-}"
CALLER_GIT_SSH_STRICT_HOST_CHECKING="${GIT_SSH_STRICT_HOST_CHECKING:-}"
CALLER_GITHUB_BACKUP_PAT="${GITHUB_BACKUP_PAT:-}"

if [[ -f "${SCRIPT_DIR}/../config/backup.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/backup.env"
fi

S3_BUCKET_URL="${S3_BUCKET_URL:-s3://compnova-git-immutable-vault}"
GITHUB_REPO_LIST="${CALLER_GITHUB_REPO_LIST:-${GITHUB_REPO_LIST:-}}"
GITHUB_REPO="${CALLER_GITHUB_REPO:-${GITHUB_REPO:-}}"
S3_FAILSAFE_PREFIX="${S3_FAILSAFE_PREFIX:-path-b-failsafe-mirror}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSE_ALGORITHM="${SSE_ALGORITHM:-AES256}"
SSE_KMS_KEY_ID="${SSE_KMS_KEY_ID:-}"
ENABLE_OBJECT_LOCK="${ENABLE_OBJECT_LOCK:-true}"
OBJECT_LOCK_MODE="${OBJECT_LOCK_MODE:-COMPLIANCE}"
OBJECT_LOCK_RETENTION_DAYS="${OBJECT_LOCK_RETENTION_DAYS:-365}"

# Out-of-band Git authentication for the external backup host
# (explicit caller env wins over config; config is the source of truth otherwise).
GIT_AUTH_MODE="${CALLER_GIT_AUTH_MODE:-${GIT_AUTH_MODE:-ssh}}"
GIT_SSH_KEY_FILE="${CALLER_GIT_SSH_KEY_FILE:-${GIT_SSH_KEY_FILE:-}}"
GIT_SSH_KNOWN_HOSTS_FILE="${CALLER_GIT_SSH_KNOWN_HOSTS_FILE:-${GIT_SSH_KNOWN_HOSTS_FILE:-}}"
GIT_SSH_STRICT_HOST_CHECKING="${CALLER_GIT_SSH_STRICT_HOST_CHECKING:-${GIT_SSH_STRICT_HOST_CHECKING:-accept-new}}"
GITHUB_BACKUP_PAT="${CALLER_GITHUB_BACKUP_PAT:-${GITHUB_BACKUP_PAT:-}}"

# ------------------------------------------------------------------------------
# Failure-isolation guard: Path B's scheduler lives in external-timer/, not
# in this repository. An accidental in-repo `schedule:` trigger would both
# duplicate nightly objects and die together with the repo it protects.
# ------------------------------------------------------------------------------
if [[ "${GITHUB_EVENT_NAME:-}" == "schedule" && "${ALLOW_IN_REPO_SCHEDULED_FALLBACK:-false}" != "true" ]]; then
  echo "[ERROR] Path B refusing to run from an in-repo scheduled workflow." >&2
  echo "        The scheduled Path B runner is the external timer in external-timer/" >&2
  echo "        (compnova-git-failsafe-backup.timer or compnova-git-failsafe.cron) on the" >&2
  echo "        dedicated backup host. Running both would create duplicate nightly backups" >&2
  echo "        and break failure isolation if the repository is deleted." >&2
  echo "        Use 'workflow_dispatch' for a manual fallback run, or set" >&2
  echo "        ALLOW_IN_REPO_SCHEDULED_FALLBACK=true only if a second scheduler is intended." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Repository list to mirror (priority: explicit caller URL > GITHUB_REPO_LIST >
# GITHUB_REPO > GITHUB_REPO_URL).
# ------------------------------------------------------------------------------
REPO_ENTRIES=()
if [[ -n "${CALLER_GITHUB_REPO_URL}" ]]; then
  # Path B workflow manual-fallback path: single explicit URL. Must keep working.
  REPO_ENTRIES+=("${CALLER_GITHUB_REPO_URL}")
else
  _list_raw="${GITHUB_REPO_LIST:-}"
  _list_raw="${_list_raw//,/ }"
  _list_raw="${_list_raw//$'\n'/ }"
  _list_raw="${_list_raw//$'\t'/ }"
  for _entry in ${_list_raw}; do
    REPO_ENTRIES+=("${_entry}")
  done
  if [[ ${#REPO_ENTRIES[@]} -eq 0 ]]; then
    if [[ -n "${GITHUB_REPO:-}" ]]; then
      REPO_ENTRIES+=("${GITHUB_REPO}")
    elif [[ -n "${GITHUB_REPO_URL:-}" ]]; then
      REPO_ENTRIES+=("${GITHUB_REPO_URL}")
    else
      echo "[ERROR] Nothing to mirror: set GITHUB_REPO_LIST, GITHUB_REPO or GITHUB_REPO_URL in config/backup.env." >&2
      exit 1
    fi
  fi
fi
TOTAL_REPOS=${#REPO_ENTRIES[@]}

# ------------------------------------------------------------------------------
# Build GIT_SSH_COMMAND from config (ssh mode). IdentitiesOnly is set only when
# a dedicated key file is configured.
# ------------------------------------------------------------------------------
if [[ "${GIT_AUTH_MODE}" == "ssh" ]]; then
  _ssh_cmd="ssh -o StrictHostKeyChecking=${GIT_SSH_STRICT_HOST_CHECKING}"
  if [[ -n "${GIT_SSH_KNOWN_HOSTS_FILE}" ]]; then
    _ssh_cmd="${_ssh_cmd} -o UserKnownHostsFile=${GIT_SSH_KNOWN_HOSTS_FILE}"
  fi
  if [[ -n "${GIT_SSH_KEY_FILE}" ]]; then
    _ssh_cmd="${_ssh_cmd} -i ${GIT_SSH_KEY_FILE} -o IdentitiesOnly=yes"
  fi
  export GIT_SSH_COMMAND="${_ssh_cmd}"
fi

# Strip credentials from any URL before printing (never log a token).
mask_url() {
  printf '%s\n' "$1" | sed -e 's#://[^@/]*@#://***@#'
}

entry_is_url() {
  case "$1" in
    *://*|git@*:*) return 0 ;;
  esac
  return 1
}

entry_repo_name() {
  local _name="${1##*/}"
  printf '%s\n' "${_name%.git}"
}

entry_clone_url() {
  local _entry="$1"
  if entry_is_url "${_entry}"; then
    printf '%s\n' "${_entry}"
    return 0
  fi
  if [[ "${GIT_AUTH_MODE}" == "https" ]]; then
    if [[ -z "${GITHUB_BACKUP_PAT}" ]]; then
      echo "[ERROR] GIT_AUTH_MODE=https requires GITHUB_BACKUP_PAT for entry '${_entry}'." >&2
      return 1
    fi
    printf 'https://x-access-token:%s@github.com/%s.git\n' "${GITHUB_BACKUP_PAT}" "${_entry}"
  else
    printf 'git@github.com:%s.git\n' "${_entry}"
  fi
}

# ------------------------------------------------------------------------------
# Preflight auth check: fail fast with an actionable message BEFORE cloning.
# ------------------------------------------------------------------------------
preflight_repo_auth() {
  local _url="$1" _shown
  _shown="$(mask_url "${_url}")"
  case "${_url}" in
    http://*|https://*)
      if [[ "${_url}" != *"x-access-token:"* && -z "${GITHUB_BACKUP_PAT}" ]]; then
        echo "  -> FAIL: HTTPS target carries no token; embed x-access-token in the URL or set GITHUB_BACKUP_PAT (GIT_AUTH_MODE=${GIT_AUTH_MODE})." >&2
        return 1
      fi
      ;;
    *)
      if [[ "${GIT_AUTH_MODE}" != "ssh" ]]; then
        echo "  -> FAIL: SSH-style target '${_shown}' but GIT_AUTH_MODE=${GIT_AUTH_MODE}; set GIT_AUTH_MODE=ssh or use owner/repo entries." >&2
        return 1
      fi
      if [[ -n "${GIT_SSH_KEY_FILE}" ]]; then
        if [[ ! -f "${GIT_SSH_KEY_FILE}" ]]; then
          echo "  -> FAIL: deploy key file missing: ${GIT_SSH_KEY_FILE} (GIT_AUTH_MODE=ssh)." >&2
          echo "     Create it: ssh-keygen -t ed25519 -f ${GIT_SSH_KEY_FILE} -N ''" >&2
          echo "     then add ${GIT_SSH_KEY_FILE}.pub to GitHub as a read-only deploy key." >&2
          return 1
        fi
        if [[ ! -r "${GIT_SSH_KEY_FILE}" ]]; then
          echo "  -> FAIL: deploy key file not readable: ${GIT_SSH_KEY_FILE}" >&2
          return 1
        fi
      fi
      if [[ -n "${GIT_SSH_KNOWN_HOSTS_FILE}" && ! -f "${GIT_SSH_KNOWN_HOSTS_FILE}" ]]; then
        if [[ -d "$(dirname "${GIT_SSH_KNOWN_HOSTS_FILE}")" ]] && touch "${GIT_SSH_KNOWN_HOSTS_FILE}" 2>/dev/null; then
          echo "  -> NOTE: created ${GIT_SSH_KNOWN_HOSTS_FILE}; github.com will be pinned on first connect (StrictHostKeyChecking=${GIT_SSH_STRICT_HOST_CHECKING})."
        else
          echo "  -> FAIL: known_hosts file ${GIT_SSH_KNOWN_HOSTS_FILE} is missing and cannot be created." >&2
          echo "     Seed it: ssh-keyscan -t ed25519 github.com >> ${GIT_SSH_KNOWN_HOSTS_FILE}" >&2
          return 1
        fi
      fi
      ;;
  esac
  local _err _msg
  _err="$(mktemp -t compnova-preflight-XXXXXX)"
  if GIT_TERMINAL_PROMPT=0 git ls-remote --heads "${_url}" >/dev/null 2>"${_err}"; then
    rm -f "${_err}"
    echo "  -> PASS: git ls-remote authenticated against ${_shown} (auth mode: ${GIT_AUTH_MODE})"
    return 0
  fi
  _msg="$(cat "${_err}" 2>/dev/null || true)"
  rm -f "${_err}"
  # Scrub credentials both as embedded URL userinfo and as the raw PAT value.
  _msg="$(printf '%s\n' "${_msg}" | sed -e 's#://[^@/]*@#://***@#g')"
  if [[ -n "${GITHUB_BACKUP_PAT}" ]]; then
    _msg="${_msg//${GITHUB_BACKUP_PAT}/***REDACTED***}"
  fi
  echo "  -> FAIL: git ls-remote --heads ${_shown} failed (GIT_AUTH_MODE=${GIT_AUTH_MODE}, ssh key: ${GIT_SSH_KEY_FILE:-none}, known_hosts: ${GIT_SSH_KNOWN_HOSTS_FILE:-ssh default})." >&2
  echo "     git said: ${_msg%%$'\n'*}" >&2
  echo "     Remediation: confirm the deploy key/PAT grants read access to this repo;" >&2
  echo "     for SSH host-key issues run: ssh-keyscan -t ed25519 github.com >> ${GIT_SSH_KNOWN_HOSTS_FILE:-~/.ssh/known_hosts}" >&2
  return 1
}

# ------------------------------------------------------------------------------
# Per-repo pipeline. Every critical step returns explicitly (the caller treats
# a failure as per-repo, not run-fatal).
# ------------------------------------------------------------------------------
backup_one_repo() {
  local _entry="$1"
  local REPO_NAME _url _shown
  if [[ -n "${CALLER_REPO_NAME}" && ${TOTAL_REPOS} -eq 1 ]]; then
    REPO_NAME="${CALLER_REPO_NAME}"
  else
    REPO_NAME="$(entry_repo_name "${_entry}")"
  fi
  _url="$(entry_clone_url "${_entry}")" || return 1
  _shown="$(mask_url "${_url}")"

  local TIMESTAMP_UTC DATE_PARTITION ART_DIR MIRROR_DIR ARCHIVE_NAME ARCHIVE_PATH BUNDLE_NAME BUNDLE_PATH
  TIMESTAMP_UTC="$(date -u +"%Y%m%dT%H%M%SZ")"
  DATE_PARTITION="$(date -u +"%Y/%m/%d")"
  ART_DIR="${WORK_DIR}/${REPO_NAME}"
  mkdir -p "${ART_DIR}" || return 1
  MIRROR_DIR="${ART_DIR}/${REPO_NAME}.git"
  ARCHIVE_NAME="${REPO_NAME}-mirror-${TIMESTAMP_UTC}.tar.gz"
  ARCHIVE_PATH="${ART_DIR}/${ARCHIVE_NAME}"
  BUNDLE_NAME="${REPO_NAME}-mirror-${TIMESTAMP_UTC}.bundle"
  BUNDLE_PATH="${ART_DIR}/${BUNDLE_NAME}"

  echo "[preflight] Repo '${REPO_NAME}' <- ${_shown} (GIT_AUTH_MODE=${GIT_AUTH_MODE})"
  preflight_repo_auth "${_url}" || return 1

  echo "[1/5] Cloning bare mirror (all branches, tags, and refs)..."
  git clone --mirror "${_url}" "${MIRROR_DIR}" || return 1

  git -C "${MIRROR_DIR}" remote update --prune || return 1
  HEAD_COMMIT="$(git -C "${MIRROR_DIR}" rev-parse HEAD 2>/dev/null || echo 'bare-mirror')"
  BRANCH_COUNT="$(git -C "${MIRROR_DIR}" for-each-ref refs/heads | wc -l | tr -d ' ')"
  TAG_COUNT="$(git -C "${MIRROR_DIR}" for-each-ref refs/tags | wc -l | tr -d ' ')"

  echo "[2/5] Creating full-history bundle and compressed bare mirror archive..."
  git -C "${MIRROR_DIR}" bundle create "${BUNDLE_PATH}" --all || return 1
  git -C "${MIRROR_DIR}" bundle verify "${BUNDLE_PATH}" || return 1

  tar -czf "${ARCHIVE_PATH}" -C "${ART_DIR}" "${REPO_NAME}.git" || return 1

  UPLOAD_ARCHIVE="${ARCHIVE_PATH}"
  UPLOAD_FILENAME="${ARCHIVE_NAME}"

  if [[ -n "${BACKUP_ENCRYPTION_PASSPHRASE:-}" ]]; then
    echo "[3/5] Encrypting mirror archive with AES-256-CBC..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
      -in "${ARCHIVE_PATH}" \
      -out "${ARCHIVE_PATH}.enc" \
      -pass env:BACKUP_ENCRYPTION_PASSPHRASE || return 1
    UPLOAD_ARCHIVE="${ARCHIVE_PATH}.enc"
    UPLOAD_FILENAME="${ARCHIVE_NAME}.enc"
  else
    echo "[3/5] Using AWS S3 Server-Side Encryption (${SSE_ALGORITHM})..."
  fi

  SHA256_SUM="$(sha256sum "${UPLOAD_ARCHIVE}" | awk '{print $1}')"
  BUNDLE_SHA256="$(sha256sum "${BUNDLE_PATH}" | awk '{print $1}')"

  MANIFEST_PATH="${ART_DIR}/${UPLOAD_FILENAME}.manifest.json"
  cat > "${MANIFEST_PATH}" <<EOF
{
  "backup_type": "PATH_B_FAILSAFE_DAILY_MIRROR",
  "repository": "${REPO_NAME}",
  "source": "${_shown}",
  "head_commit": "${HEAD_COMMIT}",
  "branch_count": ${BRANCH_COUNT},
  "tag_count": ${TAG_COUNT},
  "timestamp_utc": "${TIMESTAMP_UTC}",
  "mirror_archive": "${UPLOAD_FILENAME}",
  "mirror_archive_sha256": "${SHA256_SUM}",
  "bundle_archive": "${BUNDLE_NAME}",
  "bundle_sha256": "${BUNDLE_SHA256}",
  "s3_bucket_url": "${S3_BUCKET_URL}",
  "object_lock_mode": "${OBJECT_LOCK_MODE}",
  "object_lock_retention_days": ${OBJECT_LOCK_RETENTION_DAYS}
}
EOF

  # Per-repo sub-prefix so multiple mirrored repos never collide.
  DEST_PARTITION="${S3_FAILSAFE_PREFIX}/${REPO_NAME}/${DATE_PARTITION}"
  DEST_ARCHIVE_URI="${S3_BUCKET_URL}/${DEST_PARTITION}/${UPLOAD_FILENAME}"
  DEST_BUNDLE_URI="${S3_BUCKET_URL}/${DEST_PARTITION}/${BUNDLE_NAME}"
  DEST_MANIFEST_URI="${S3_BUCKET_URL}/${DEST_PARTITION}/${UPLOAD_FILENAME}.manifest.json"

  echo "[4/5] Uploading fail-safe mirror & bundle to locked S3 storage..."
  aws s3 cp "${UPLOAD_ARCHIVE}" "${DEST_ARCHIVE_URI}" \
    --region "${AWS_REGION}" \
    "${SSE_ARGS[@]}" \
    --metadata "backup_type=failsafe_mirror,repo=${REPO_NAME},sha256=${SHA256_SUM}" || return 1

  aws s3 cp "${BUNDLE_PATH}" "${DEST_BUNDLE_URI}" \
    --region "${AWS_REGION}" \
    "${SSE_ARGS[@]}" \
    --metadata "backup_type=failsafe_bundle,repo=${REPO_NAME},sha256=${BUNDLE_SHA256}" || return 1

  aws s3 cp "${MANIFEST_PATH}" "${DEST_MANIFEST_URI}" \
    --region "${AWS_REGION}" \
    "${SSE_ARGS[@]}" || return 1

  if [[ "${ENABLE_OBJECT_LOCK}" == "true" ]]; then
    RETAIN_UNTIL="$(date -u -d "+${OBJECT_LOCK_RETENTION_DAYS} days" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int('${OBJECT_LOCK_RETENTION_DAYS}'))).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
    echo "[5/5] Enforcing S3 Object Lock (${OBJECT_LOCK_MODE} until ${RETAIN_UNTIL})..."
    for KEY in "${DEST_PARTITION}/${UPLOAD_FILENAME}" "${DEST_PARTITION}/${BUNDLE_NAME}" "${DEST_PARTITION}/${UPLOAD_FILENAME}.manifest.json"; do
      aws s3api put-object-retention \
        --bucket "${BUCKET_NAME}" \
        --key "${KEY}" \
        --retention "Mode=${OBJECT_LOCK_MODE},RetainUntilDate=${RETAIN_UNTIL}" \
        --region "${AWS_REGION}" 2>/dev/null || echo "Note: Relying on bucket-level default Object Lock configuration for ${KEY}."
    done
  else
    echo "[5/5] Completed upload."
  fi

  echo "------------------------------------------------------------------"
  echo "[Path B] Repo '${REPO_NAME}' SUCCESS"
  echo "  Mirror Archive : ${DEST_ARCHIVE_URI}"
  echo "  Bundle Archive : ${DEST_BUNDLE_URI}"
  echo "  Manifest       : ${DEST_MANIFEST_URI}"
  echo "  Branches/Tags  : ${BRANCH_COUNT} branches, ${TAG_COUNT} tags"
  echo "------------------------------------------------------------------"
  return 0
}

# Normalize S3_BUCKET_URL
S3_BUCKET_URL="${S3_BUCKET_URL%/}"
BUCKET_NAME="${S3_BUCKET_URL#s3://}"
BUCKET_NAME="${BUCKET_NAME%%/*}"

WORK_DIR="$(mktemp -d -t compnova-failsafe-mirror-XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

SSE_ARGS=(--sse "${SSE_ALGORITHM}")
if [[ "${SSE_ALGORITHM}" == "aws:kms" && -n "${SSE_KMS_KEY_ID}" ]]; then
  SSE_ARGS+=(--sse-kms-key-id "${SSE_KMS_KEY_ID}")
fi

echo "=================================================================="
echo "[Path B: Fail-Safe Daily Mirror] Starting external mirror pull"
echo "Target S3 Bucket URL: ${S3_BUCKET_URL}"
echo "Git Auth Mode       : ${GIT_AUTH_MODE} (ssh key: ${GIT_SSH_KEY_FILE:-none})"
echo "Repositories        : ${TOTAL_REPOS}"
for _entry in "${REPO_ENTRIES[@]}"; do
  echo "  - $(mask_url "${_entry}") -> $(entry_repo_name "${_entry}")"
done
echo "=================================================================="

OK_REPOS=()
FAILED_REPOS=()
_idx=0
for _entry in "${REPO_ENTRIES[@]}"; do
  _idx=$((_idx + 1))
  _rname="$(entry_repo_name "${_entry}")"
  echo ""
  echo "########## [Path B] Repository ${_idx}/${TOTAL_REPOS}: ${_rname} ##########"
  if backup_one_repo "${_entry}"; then
    OK_REPOS+=("${_rname}")
  else
    echo "[ERROR] Path B backup FAILED for repository '${_rname}' - continuing with remaining repositories." >&2
    FAILED_REPOS+=("${_rname}")
  fi
done

echo ""
echo "=================================================================="
echo "[Path B: Fail-Safe Daily Mirror] Aggregate summary"
for _r in ${OK_REPOS[@]+"${OK_REPOS[@]}"}; do
  echo "  SUCCESS : ${_r}"
done
for _r in ${FAILED_REPOS[@]+"${FAILED_REPOS[@]}"}; do
  echo "  FAILED  : ${_r}"
done
if [[ ${#FAILED_REPOS[@]} -gt 0 ]]; then
  echo "[Path B] ${#FAILED_REPOS[@]} of ${TOTAL_REPOS} repositories FAILED (successful uploads kept)." >&2
  echo "=================================================================="
  exit 1
fi
echo "[Path B] All ${TOTAL_REPOS} repositories mirrored successfully."
echo "=================================================================="

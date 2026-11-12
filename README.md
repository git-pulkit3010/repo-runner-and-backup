# CompNova Lean GitHub Security & Dual-Path Automated Backup

This package implements the **Lean GitHub Security & Automated Backup** architecture from the CompNova presentation (`Lean GitHub Security & Backup Architecture - CompNova.pptx`), delivering private repository controls, role-based PR reviews, `$0` local secret scanning, and dual-path immutable S3 backups.

## Global S3 Bucket URL Configuration (`S3_BUCKET_URL`)

The S3 storage bucket URL is exposed as an easily editable global variable (`S3_BUCKET_URL`) in:
1. **`config/backup.env`** — Central configuration sourced automatically by all backup, vault provisioning, and restore scripts.
2. **`.github/workflows/path-a-realtime-s3-backup.yml`** — Top-level `env.S3_BUCKET_URL` for Path A (Real-Time Commit Backup).
3. **`.github/workflows/path-b-daily-failsafe-mirror.yml`** — Top-level `env.S3_BUCKET_URL` for Path B (Daily Scheduled Fail-Safe Backup).
4. **Each script in `scripts/`** — Fallback default `S3_BUCKET_URL="${S3_BUCKET_URL:-s3://compnova-git-immutable-vault}"` at the top of the file.

## Architecture Mapping

### 01 / Repository Controls (Slide 2 Compliances)
| Control | Implementation File(s) | Description |
| :--- | :--- | :--- |
| **Access & Privacy** | `scripts/verify_repo_compliance.sh` | Verifies/enforces `private: true` repository visibility and audits mandatory 2FA on the GitHub organization. |
| **Branch Protection** | `scripts/verify_repo_compliance.sh`, `.github/CODEOWNERS`, `config/backup.env` | Enforces required PR reviews via GitHub Team (`@compnova/core-reviewers`), stale review dismissal, status checks, and blocks force-pushes/deletions — applied to **every** branch in `PROTECTED_BRANCHES` and drift-checked against the workflow trigger lists in `--audit-only` mode. |
| **Local Secret Checks** | `scripts/pre-commit-secret-scan.sh`, `.githooks/pre-commit`, `.pre-commit-config.yaml`, `scripts/install_hooks.sh` | Blocks accidental credential leaks (AWS keys, GitHub PATs, private keys, SAP/DB passwords, `.env` files) locally before commit and in CI via `.github/workflows/pr-security-compliance.yml`. CI installs the **pinned gitleaks** binary (same `v8.18.4` as `.pre-commit-config.yaml`; download is non-fatal) and the built-in python scanner resolves the diff range from `SCAN_BASE_SHA`/`GITHUB_BASE_SHA`/`GITHUB_EVENT_BEFORE`/`GITHUB_BASE_REF`, falling back to a **full-history scan** (optionally capped via `SCAN_MAX_COMMITS`). |
| **Immutable Vault** | `scripts/setup_immutable_s3_vault.sh` | Provisions the isolated AWS S3 bucket (`S3_BUCKET_URL`) with S3 Versioning, Public Access Block, AES-256 Server-Side Encryption, and S3 Object Lock (`COMPLIANCE` mode). |

### 02 / Operational Flow: Dual-Path Backup Workflow (Slide 3)
| Path | Trigger | Workflow / Timer | Script | Description |
| :--- | :--- | :--- | :--- | :--- |
| **Path A: Real-Time** | Every Commit merged to a protected branch (`PROTECTED_BRANCHES`) | `.github/workflows/path-a-realtime-s3-backup.yml` | `scripts/realtime_bundle_backup.sh` | Single job, full Git history checked out exactly once (`fetch-depth: 0`, `fetch-tags: true`): advisory secret scan + compliance audit (non-blocking, surfaced as `::warning::` annotations and a step-summary entry so a clean commit always reaches S3), then a full-history `git bundle --all` with SHA-256 manifest uploaded encrypted to `S3_BUCKET_URL` (bundle **and** manifest get explicit Object Lock retention). The blocking merge gate is `pr-security-compliance.yml` + branch protection. |
| **Path B: Fail-Safe** | **Daily schedule via the EXTERNAL timer only** (outside the repo — failure isolation) | Scheduled runner: `external-timer/compnova-git-failsafe-backup.timer` / `external-timer/compnova-git-failsafe.cron`. Manual fallback only: `.github/workflows/path-b-daily-failsafe-mirror.yml` (`workflow_dispatch`; it has **no** `schedule:` trigger — re-enabling one would duplicate nightly objects and break failure isolation) | `scripts/failsafe_mirror_backup.sh` | Runs `git clone --mirror` for **every repo in `GITHUB_REPO_LIST`**, packages both a `.tar.gz` bare mirror and a `.bundle` per repo, and uploads under the per-repo key layout `s3://.../path-b-failsafe-mirror/<repo-name>/YYYY/MM/DD/...` with 365-day Object Lock retention (archive, bundle **and** manifest). One failing repo never blocks the others; the run still exits non-zero so the timer surfaces it. |

## AWS Authentication: OIDC Preferred (`AWS_ROLE_ARN`)

Both GitHub workflows prefer **passwordless OIDC role federation**: set the repository/organization secret `AWS_ROLE_ARN` to an IAM role trusted by your GitHub OIDC provider (`sub=repo:<org>/<repo>:...`, `aud=sts.amazonaws.com` — the default GitHub Actions OIDC audience) and grant it `s3:PutObject` on the vault. When `AWS_ROLE_ARN` is set, the static-key step is skipped — **you can then delete `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from repo secrets**. If it is unset, the workflows fall back to the long-lived static keys (still supported, not recommended).

## Secret Scan Ignore Markers

False positives can only be suppressed with these **case-sensitive, exact-token** markers on the offending line (generic words like `example`/`placeholder` deliberately do **not** ignore anything):

- `pragma: allowlist secret` (pre-commit standard)
- `gitleaks:allow` (gitleaks standard)
- `compnova:allow-secret` (this package's explicit marker)

```python
DEBUG_WEBHOOK = "xoxb-0000000000-0000000000-aaaa"  # compnova:allow-secret
```

## Configuration Reference (`config/backup.env`)

| Variable | Purpose |
| :--- | :--- |
| `S3_BUCKET_URL` | Immutable vault URL (single source of truth; default `s3://compnova-git-immutable-vault`). |
| `PROTECTED_BRANCHES` | Space/comma-separated branches that workflows trigger on **and** that branch protection must cover (`main master production`). `verify_repo_compliance.sh --audit-only` reports `FAIL (drift)` against `.github/workflows/path-a-realtime-s3-backup.yml` and `pr-security-compliance.yml`. |
| `PROTECTED_BRANCH` | Primary/default branch; kept for backward compatibility and used as fallback when `PROTECTED_BRANCHES` is unset. |
| `GITHUB_REPO_LIST` | Space/comma/newline-separated `owner/repo` list mirrored by Path B (add entries to scale across repos — no code change). |
| `GITHUB_REPO_URL` / `GITHUB_REPO` | Single-repo fallbacks when `GITHUB_REPO_LIST` is unset; an explicit `GITHUB_REPO_URL` **environment** override (used by the Path B manual-fallback workflow) always wins. |
| `GIT_AUTH_MODE` | Path B auth on the external host: `ssh` (deploy key, default) or `https` (`GITHUB_BACKUP_PAT`). |
| `GIT_SSH_KEY_FILE` / `GIT_SSH_KNOWN_HOSTS_FILE` / `GIT_SSH_STRICT_HOST_CHECKING` | SSH deploy-key path, known_hosts path, and host-checking mode (`accept-new`). The script exports `GIT_SSH_COMMAND` and preflights with `git ls-remote` before cloning, failing fast with actionable guidance (tokens are never logged). |
| `GITHUB_BACKUP_PAT` | HTTPS-mode PAT (read-only Contents) for every repo in `GITHUB_REPO_LIST`; provide via environment, never commit. |
| `ALLOW_IN_REPO_SCHEDULED_FALLBACK` | Guard hatch (default `false`): Path B aborts if run with `GITHUB_EVENT_NAME=schedule` because scheduling must live in `external-timer/`, not in the repo. |

## Operational Warnings (read before enabling)

- **Path B needs a host that already exists.** The external timer runs on a Linux
  host/VM that is *outside* the repository — that isolation is the whole point of
  the fail-safe path. Spinning up a dedicated cloud VM purely to run it adds
  recurring cost; co-locate it on an existing CompNova server instead. GitHub
  Actions minutes and the S3 penny tier are the only other running costs.
- **S3 Object Lock in `COMPLIANCE` mode is irreversible.** Neither the bucket
  owner nor the AWS account root can delete an object or shorten its retention
  before `RetainUntilDate` passes (90 days for Path A, 365 days for Path B).
  That is the point — it defeats ransomware and insider deletion — but it also
  means an accidentally pushed large binary or test artifact becomes
  **non-deletable and billable** until the retention window expires. Keep large
  artifacts out of the repo, and reconcile the S3 bill against the vault's
  growth before the first year-long retention period lands.

## Quick Start

1. **Edit `S3_BUCKET_URL`**:
   Update `S3_BUCKET_URL` in `config/backup.env` and the top `env:` block of `.github/workflows/*.yml`.
2. **Provision the Immutable S3 Vault**:
   ```bash
   ./scripts/setup_immutable_s3_vault.sh
   ```
3. **Install Local Pre-Commit Secret Scanning Hooks**:
   ```bash
   ./scripts/install_hooks.sh
   ```
4. **Enforce GitHub Private Visibility, 2FA Check & Team Branch Protection on all `PROTECTED_BRANCHES`**:
   ```bash
   GH_TOKEN="<admin-pat>" ./scripts/verify_repo_compliance.sh --enforce
   ```
5. **Configure External Timer for Path B (the only scheduled runner)**:
   Copy the repository scripts to `/opt/compnova-backup` on your external host, prepare out-of-band Git auth once:
   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_compnova_backup -N ""
   ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts
   # add /root/.ssh/id_ed25519_compnova_backup.pub as a read-only deploy key
   # for every repo listed in GITHUB_REPO_LIST
   ```
   then enable `external-timer/compnova-git-failsafe-backup.timer` (or install `external-timer/compnova-git-failsafe.cron`). `.github/workflows/path-b-daily-failsafe-mirror.yml` stays available for **manual** `workflow_dispatch` fallback runs only.

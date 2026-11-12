#!/usr/bin/env bash
# ==============================================================================
# CompNova Repository Controls - Compliance Verification & Enforcement
# Enforces Slide 2 Core Security Components:
# 1. Access & Privacy: Private repo visibility + Mandatory Organization 2FA
# 2. Branch Protection: Required PR reviews via GitHub Team + Admin enforcement
#    applied to EVERY branch in PROTECTED_BRANCHES (kept in sync with the
#    GitHub workflow trigger lists, which --audit-only drift-checks).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Capture caller-provided overrides BEFORE sourcing config/backup.env so the
# workflows (which run against their own repository/ref) keep priority over
# the config defaults.
CALLER_GITHUB_REPO="${GITHUB_REPO:-}"
CALLER_PROTECTED_BRANCHES="${PROTECTED_BRANCHES:-}"
CALLER_PROTECTED_BRANCH="${PROTECTED_BRANCH:-}"

if [[ -f "${SCRIPT_DIR}/../config/backup.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/backup.env"
fi

MODE="${1:---audit-only}" # Pass --enforce to apply settings via GitHub API
GITHUB_REPO="${CALLER_GITHUB_REPO:-${GITHUB_REPO:-compnova/sap-server}}"
GITHUB_ORG="${GITHUB_ORG:-${GITHUB_REPO%%/*}}"
PROTECTED_BRANCHES="${CALLER_PROTECTED_BRANCHES:-${PROTECTED_BRANCHES:-}}"
PROTECTED_BRANCH="${CALLER_PROTECTED_BRANCH:-${PROTECTED_BRANCH:-main}}"
GITHUB_REVIEW_TEAM_SLUG="${GITHUB_REVIEW_TEAM_SLUG:-core-reviewers}"
REQUIRED_APPROVING_REVIEWS="${REQUIRED_APPROVING_REVIEWS:-1}"

# Branch list: PROTECTED_BRANCHES (space or comma separated) wins; fall back
# to the single legacy PROTECTED_BRANCH when unset.
BRANCH_LIST=()
_list_raw="${PROTECTED_BRANCHES:-}"
_list_raw="${_list_raw//,/ }"
_list_raw="${_list_raw//$'\n'/ }"
_list_raw="${_list_raw//$'\t'/ }"
for _b in ${_list_raw}; do
  BRANCH_LIST+=("${_b}")
done
if [[ ${#BRANCH_LIST[@]} -eq 0 ]]; then
  BRANCH_LIST+=("${PROTECTED_BRANCH}")
fi

echo "=================================================================="
echo "[CompNova Compliance Check] Auditing Repository: ${GITHUB_REPO}"
echo "Mode: ${MODE}"
echo "Protected Branches (${#BRANCH_LIST[@]}): ${BRANCH_LIST[*]}"
echo "=================================================================="

if ! command -v gh >/dev/null 2>&1; then
  echo "[WARN] GitHub CLI (gh) not installed; skipping remote API compliance check."
  exit 0
fi

if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
  echo "[WARN] No GH_TOKEN/GITHUB_TOKEN provided; skipping remote API compliance check."
  exit 0
fi

# 1. Verify Private Repository Visibility
echo "[1/4] Checking Private Repository Visibility..."
IS_PRIVATE="$(gh api "repos/${GITHUB_REPO}" --jq '.private' 2>/dev/null || echo 'unknown')"
if [[ "${IS_PRIVATE}" == "true" ]]; then
  echo "  -> PASS: Repository '${GITHUB_REPO}' is private."
elif [[ "${MODE}" == "--enforce" ]]; then
  echo "  -> ENFORCING: Setting repository '${GITHUB_REPO}' visibility to private..."
  gh api -X PATCH "repos/${GITHUB_REPO}" -f visibility=private -F private=true >/dev/null
  echo "  -> FIXED: Repository is now private."
else
  echo "  -> FAIL: Repository '${GITHUB_REPO}' is NOT private (private=${IS_PRIVATE})."
  exit 1
fi

# 2. Verify Mandatory 2FA on GitHub Organization
echo "[2/4] Checking Mandatory 2FA on Organization '${GITHUB_ORG}'..."
TWO_FACTOR="$(gh api "orgs/${GITHUB_ORG}" --jq '.two_factor_requirement_enabled' 2>/dev/null || echo 'unknown')"
if [[ "${TWO_FACTOR}" == "true" ]]; then
  echo "  -> PASS: Mandatory 2FA is enabled for organization '${GITHUB_ORG}'."
else
  echo "  -> WARN: Organization 2FA check returned '${TWO_FACTOR}' (requires org owner token or personal account 2FA)."
fi

# 3. Verify / Enforce Branch Protection on EVERY protected branch
BRANCH_RESULTS=()
echo "[3/4] Processing Branch Protection for ${#BRANCH_LIST[@]} protected branch(es): ${BRANCH_LIST[*]}..."
if [[ "${MODE}" == "--enforce" ]]; then
  # Grant team access to the repository once (applies to all branches).
  gh api -X PUT "orgs/${GITHUB_ORG}/teams/${GITHUB_REVIEW_TEAM_SLUG}/repos/${GITHUB_REPO}" \
    -f permission=push >/dev/null 2>&1 || true
  for BRANCH in "${BRANCH_LIST[@]}"; do
    echo "  -> ENFORCING: Applying Branch Protection & Team Review Rules on '${BRANCH}'..."
    if gh api -X PUT "repos/${GITHUB_REPO}/branches/${BRANCH}/protection" \
      --input - <<EOF >/dev/null
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Block Credential Leaks & Verify Compliance"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": ${REQUIRED_APPROVING_REVIEWS},
    "require_last_push_approval": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true
}
EOF
    then
      echo "  -> PASS: Branch protection enforced on '${BRANCH}'."
      BRANCH_RESULTS+=("${BRANCH}|PASS|protection enforced (${REQUIRED_APPROVING_REVIEWS} review(s) required)")
    else
      echo "  -> FAIL: Branch protection enforcement FAILED on '${BRANCH}' (check admin token / branch exists)."
      BRANCH_RESULTS+=("${BRANCH}|FAIL|enforcement API call failed")
    fi
  done
else
  for BRANCH in "${BRANCH_LIST[@]}"; do
    BP_STATUS="$(gh api "repos/${GITHUB_REPO}/branches/${BRANCH}/protection" --jq '.required_pull_request_reviews.required_approving_review_count' 2>/dev/null || echo 'unprotected')"
    if [[ "${BP_STATUS}" != "unprotected" && "${BP_STATUS}" -ge 1 ]]; then
      echo "  -> PASS: Branch '${BRANCH}' requires ${BP_STATUS} approving PR review(s)."
      BRANCH_RESULTS+=("${BRANCH}|PASS|requires ${BP_STATUS} approving review(s)")
    else
      echo "  -> FAIL: Branch '${BRANCH}' protection query returned '${BP_STATUS}' (run with --enforce and admin token to configure)."
      BRANCH_RESULTS+=("${BRANCH}|FAIL|protection=${BP_STATUS}")
    fi
  done
fi

# 4. Drift check (audit-only): workflow branch triggers vs PROTECTED_BRANCHES.
# Reported, never hard-failed: a workflow that fires on a branch without
# protection means backups run unprotected (defect: Path B/master/production).
if [[ "${MODE}" == "--audit-only" ]]; then
  echo "[4/4] Checking workflow trigger lists for branch-protection drift..."
  python3 - "${REPO_ROOT}" "${BRANCH_LIST[@]}" <<'PY' || echo "  -> WARN (drift): parser error; compare .github/workflows/*.yml vs PROTECTED_BRANCHES manually."
import os
import sys

repo_root = sys.argv[1]
configured = sys.argv[2:]

def parse_workflow(path):
    """Minimal YAML-subset parser (mappings / block scalar lists, which is all
    these workflow files use at the paths we read). Avoids third-party deps."""
    root = {}
    stack = [{"indent": -1, "container": root, "parent": None, "key": None}]
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        while len(stack) > 1 and indent <= stack[-1]["indent"]:
            stack.pop()
        frame = stack[-1]
        container = frame["container"]
        if stripped.startswith("-"):
            value = stripped[1:].strip().strip("\"'")
            if isinstance(container, dict) and not container and frame["parent"] is not None:
                converted = []
                frame["container"] = converted
                frame["parent"][frame["key"]] = converted
                container = converted
            if isinstance(container, list):
                container.append(value)
            continue
        if not isinstance(container, dict):
            # Key line nested under a sequence item (e.g. a step's `uses:`):
            # irrelevant to branch lists, skip without corrupting the tree.
            continue
        key, _, rest = stripped.partition(":")
        key = key.strip().strip("\"'")
        rest = rest.strip().strip("\"'")
        if rest.startswith("[") and rest.endswith("]"):
            container[key] = [v.strip().strip("\"'") for v in rest[1:-1].split(",") if v.strip()]
        elif rest:
            container[key] = rest
        else:
            child = {}
            container[key] = child
            stack.append({"indent": indent, "container": child, "parent": container, "key": key})
    return root

targets = [
    (".github/workflows/path-a-realtime-s3-backup.yml", "push"),
    (".github/workflows/pr-security-compliance.yml", "pull_request"),
]
configured_set = set(configured)
for rel_path, event in targets:
    full_path = os.path.join(repo_root, rel_path)
    try:
        tree = parse_workflow(full_path)
    except OSError:
        print("  -> WARN (drift): cannot read {}".format(rel_path))
        continue
    on_block = tree.get("on") if isinstance(tree, dict) else None
    event_block = on_block.get(event) if isinstance(on_block, dict) else None
    branches = event_block.get("branches") if isinstance(event_block, dict) else None
    if not isinstance(branches, list) or not branches:
        print("  -> WARN (drift): could not parse on.{}.branches from {}".format(event, rel_path))
        continue
    workflow_set = set(branches)
    extra = sorted(workflow_set - configured_set)
    missing = sorted(configured_set - workflow_set)
    if extra or missing:
        parts = []
        if extra:
            parts.append("triggered but NOT protected: {}".format(", ".join(extra)))
        if missing:
            parts.append("protected but NOT triggered: {}".format(", ".join(missing)))
        print("  -> FAIL (drift): {} on.{}.branches differs from PROTECTED_BRANCHES ({})".format(
            rel_path, event, "; ".join(parts)))
    else:
        print("  -> PASS: {} on.{}.branches matches PROTECTED_BRANCHES".format(rel_path, event))
PY
else
  echo "[4/4] Drift check skipped in --enforce mode (audit-only only)."
fi

echo "=================================================================="
echo "[CompNova Compliance Check] Branch Protection Summary"
printf "  %-16s %-6s %s\n" "BRANCH" "RESULT" "DETAIL"
for result_line in ${BRANCH_RESULTS[@]+"${BRANCH_RESULTS[@]}"}; do
  IFS='|' read -r _b _res _detail <<< "${result_line}"
  printf "  %-16s %-6s %s\n" "${_b}" "${_res}" "${_detail}"
done
echo "[CompNova Compliance Check] Completed"
echo "=================================================================="

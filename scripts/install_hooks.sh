#!/usr/bin/env bash
# ==============================================================================
# Installs local Git pre-commit and pre-push secret scanning hooks
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR="${REPO_ROOT}/.githooks"
mkdir -p "${HOOKS_DIR}"

cat > "${HOOKS_DIR}/pre-commit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
"${REPO_ROOT}/scripts/pre-commit-secret-scan.sh" --staged
EOF

cat > "${HOOKS_DIR}/pre-push" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
"${REPO_ROOT}/scripts/pre-commit-secret-scan.sh" --ci
EOF

chmod +x "${HOOKS_DIR}/pre-commit" "${HOOKS_DIR}/pre-push"
chmod +x "${REPO_ROOT}/scripts/"*.sh

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git config core.hooksPath .githooks
  echo "[CompNova] Configured git core.hooksPath to .githooks"
fi

echo "[CompNova] Local pre-commit and pre-push secret scanning hooks installed."

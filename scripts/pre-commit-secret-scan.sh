#!/usr/bin/env bash
# ==============================================================================
# CompNova Repository Controls - Local & CI Secret Checks
# Slide 2: "Pre-commit hooks blocking accidental credential leaks" ($0 scanning)
# ==============================================================================
set -euo pipefail

MODE="${1:---staged}"

echo "[CompNova Secret Guard] Scanning for accidental credential leaks (${MODE})..."

# Use gitleaks if installed on the developer laptop or runner
if command -v gitleaks >/dev/null 2>&1; then
  if [[ "${MODE}" == "--ci" ]]; then
    echo "[CompNova Secret Guard] gitleaks found on PATH; running 'gitleaks detect'..."
    if ! gitleaks detect --source . --verbose --redact; then
      echo "[BLOCKED] gitleaks reported credential leaks (see gitleaks output above)." >&2
      exit 1
    fi
  else
    echo "[CompNova Secret Guard] gitleaks found on PATH; running 'gitleaks protect --staged'..."
    if ! gitleaks protect --staged --verbose --redact; then
      echo "[BLOCKED] gitleaks reported staged credential leaks (see gitleaks output above)." >&2
      exit 1
    fi
  fi
fi

# Built-in portable regex + entropy secret detector (zero external dependencies)
python3 - "${MODE}" <<'PYEOF'
import os
import re
import subprocess
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else "--staged"

FORBIDDEN_FILE_PATTERNS = [
    r"(^|/)\.env(\.local|\.production|\.development)?$",
    r"\.(pem|key|p12|pfx|jks|keystore)$",
    r"(^|/)id_(rsa|dsa|ecdsa|ed25519)$",
]

# NOTE: pattern sources below are Python raw strings: a word boundary is the
# two ASCII characters backslash + 'b', NEVER a raw 0x08 byte. The regression
# guard after this list rejects any control byte that ever slips back in.
SECRET_PATTERNS = [
    ("AWS Access Key ID", re.compile(r"\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b")),
    ("AWS Secret Access Key", re.compile(r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*['\"][0-9a-zA-Z/+]{40}['\"]")),
    ("GitHub Personal/App Token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{36,255}(?![A-Za-z0-9_])")),
    ("GitHub Fine-Grained PAT", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{80,255}(?![A-Za-z0-9_])")),
    ("Private Key Block", re.compile(r"-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----")),
    ("Slack Token", re.compile(r"\bxox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*")),
    ("Slack Webhook URL", re.compile(r"https://hooks\.slack\.com/services/T[a-zA-Z0-9_]+/B[a-zA-Z0-9_]+/[a-zA-Z0-9_]+")),
    ("Generic High-Confidence Secret Assignment", re.compile(r"(?i)(?<![A-Za-z0-9])(api[_-]?key|secret[_-]?key|client[_-]?secret|db[_-]?password|sap[_-]?password)\s*[:=]\s*['\"][A-Za-z0-9_\-!@#$%^&*+=]{16,}['\"]")),
]

# ------------------------------------------------------------------------------
# Regression guard: the shipped scanner once contained raw 0x08 (BACKSPACE)
# bytes where the two-character escape \b was intended, which silently broke
# 5 of the 9 patterns. Refuse to run if any pattern source contains raw control
# characters (< 0x20 except tab/newline) or non-ASCII whitespace.
# ------------------------------------------------------------------------------
_PATTERN_CORRUPTION = re.compile(r"[\x00-\x08\x0b-\x1f\u00a0\u2028\u2029]")
_corrupt_patterns = [name for name, rx in SECRET_PATTERNS if _PATTERN_CORRUPTION.search(rx.pattern)]
_corrupt_patterns += [
    "FORBIDDEN_FILE_PATTERN " + repr(pat)
    for pat in FORBIDDEN_FILE_PATTERNS
    if _PATTERN_CORRUPTION.search(pat)
]
if _corrupt_patterns:
    print("[BLOCKED] CompNova Secret Guard regression check: corrupt control/non-ASCII-whitespace bytes in pattern(s):", file=sys.stderr)
    for name in _corrupt_patterns:
        print("  - " + name, file=sys.stderr)
    sys.exit(2)

# Deliberate false-positive markers (case-sensitive, exact-token: the marker
# must not be glued to a longer word by letters, digits, '_' or '-'):
#   "pragma: allowlist secret"  - pre-commit standard marker
#   "gitleaks:allow"            - gitleaks standard marker
#   "compnova:allow-secret"     - this package's explicit marker, e.g.
#       SAP_SERVICE_KEY = "xoxb-0000000000-0000000000-a"  # compnova:allow-secret
# Generic words such as "example" or "placeholder" are intentionally NOT
# markers: a real secret sharing a line with such words must still be blocked.
IGNORE_LINE_MARKERS = ("pragma: allowlist secret", "gitleaks:allow", "compnova:allow-secret")
_TOKEN_EDGE = r"[A-Za-z0-9_-]"
IGNORE_LINE_REGEXES = [
    re.compile(r"(?<!" + _TOKEN_EDGE + r")" + re.escape(marker) + r"(?!" + _TOKEN_EDGE + r")")
    for marker in IGNORE_LINE_MARKERS
]

def line_is_ignored(line_text):
    return any(rx.search(line_text) for rx in IGNORE_LINE_REGEXES)

def _git(args):
    return subprocess.check_output(["git"] + args, text=True, errors="replace")

def resolve_ci_range():
    """Pick the CI diff range so an old commit in a PR branch is never skipped.
    Priority: SCAN_BASE_SHA > GITHUB_BASE_SHA > GITHUB_EVENT_BEFORE >
    GITHUB_BASE_REF > full history (no -n limit by default)."""
    for var in ("SCAN_BASE_SHA", "GITHUB_BASE_SHA"):
        base = (os.environ.get(var) or "").strip()
        if base:
            return base + "...HEAD", var
    before = (os.environ.get("GITHUB_EVENT_BEFORE") or "").strip()
    if before and set(before) != {"0"}:
        return before + "...HEAD", "GITHUB_EVENT_BEFORE"
    base_ref = (os.environ.get("GITHUB_BASE_REF") or "").strip()
    if base_ref:
        return "origin/" + base_ref + "...HEAD", "GITHUB_BASE_REF"
    return None, "full-history"

def get_files_and_diff(run_mode):
    if run_mode == "--ci":
        files_out = _git(["ls-files"])
        files = [f.strip() for f in files_out.splitlines() if f.strip()]
        rng, source = resolve_ci_range()
        if rng is not None:
            # Scan EVERY commit in the range, not just the net diff: a secret
            # that is added in one commit and removed in a later one is still
            # present in git history (and survives a non-squash merge), so the
            # net `git diff` alone would miss it. The net diff is appended as
            # well, so nothing either view sees is skipped.
            try:
                per_commit = _git(["log", "-p", "--no-color", rng])
                try:
                    net_diff = _git(["diff", "--no-color", rng])
                except subprocess.CalledProcessError:
                    net_diff = ""
                print("[CompNova Secret Guard] CI scan range: {} (resolved from {})".format(rng, source))
                return files, per_commit + "\n" + net_diff
            except subprocess.CalledProcessError:
                print("[CompNova Secret Guard] WARNING: base range '{}' unavailable; scanning FULL history instead.".format(rng), file=sys.stderr)
        # Full-history fallback: scan every commit, never just the last N.
        log_args = ["log", "-p", "--no-color"]
        cap_raw = (os.environ.get("SCAN_MAX_COMMITS") or "").strip()
        cap = int(cap_raw) if cap_raw.isdigit() and int(cap_raw) > 0 else 0
        if cap:
            try:
                total = int(_git(["rev-list", "--count", "HEAD"]).strip())
            except Exception:
                total = 0
            if total > cap:
                print("[CompNova Secret Guard] WARNING: SCAN_MAX_COMMITS={} truncated the full-history scan; "
                      "the {} oldest of {} commits were NOT scanned!!".format(cap, total - cap, total), file=sys.stderr)
                log_args += ["-n", str(cap)]
        print("[CompNova Secret Guard] CI scan range: full history (SCAN_BASE_SHA/GITHUB_BASE_SHA/"
              "GITHUB_EVENT_BEFORE/GITHUB_BASE_REF unset)")
        return files, _git(log_args)
    else:
        files_out = _git(["diff", "--cached", "--name-only", "--diff-filter=ACM"])
        files = [f.strip() for f in files_out.splitlines() if f.strip()]
        diff_out = _git(["diff", "--cached", "--no-color"])
        return files, diff_out

files, diff_text = get_files_and_diff(mode)
violations = []

for fpath in files:
    if fpath == "config/backup.env":
        continue
    for pat in FORBIDDEN_FILE_PATTERNS:
        if re.search(pat, fpath):
            violations.append(f"Forbidden sensitive file staged/committed: {fpath}")

current_file = "<unknown>"
for line in diff_text.splitlines():
    if line.startswith("+++ b/"):
        current_file = line[6:].strip()
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    if current_file.endswith("pre-commit-secret-scan.sh"):
        continue
    added_line = line[1:]
    if line_is_ignored(added_line):
        continue
    for rule_name, regex in SECRET_PATTERNS:
        if regex.search(added_line):
            violations.append(f"[{rule_name}] detected in {current_file}")

if violations:
    print("\n[BLOCKED] Accidental credential/secret leak detected by CompNova Secret Guard:", file=sys.stderr)
    for v in violations:
        print(f"  - {v}", file=sys.stderr)
    print("\nRemediation: Remove the secret, store it in GitHub Actions Secrets or environment variables, and retry.", file=sys.stderr)
    sys.exit(1)

print("[CompNova Secret Guard] PASSED: Zero credential leaks detected.")
PYEOF

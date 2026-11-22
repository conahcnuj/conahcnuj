#!/usr/bin/env bash
# conahcnuj "commit leftovers before time-budget exit" test (offline).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

printf 'partial\n' > "${WORK}/conahcnuj.mock"
printf 'leftover commit from interrupted run\n' > "${WORK}/.commit-msg"

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'TAPEEOF'
[{"login":"conahcnuj"}]
{"number": 15, "title": "leftovers commit before exit", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":124}}}}
{"number": 25}
TAPEEOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="conahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=0 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' tb/a tb/b)" \
    bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

[[ ${RC} -eq 1 ]] || { echo "FAIL: exited ${RC} (expected 1)"; cat "${LOG}"; exit 1; }
grep -q "Using coding agent's commit message: leftover commit from interrupted run" "${LOG}" || { echo "FAIL: leftover was not committed"; cat "${LOG}"; exit 1; }
grep -q "ERROR: time budget (0s) exhausted while waiting" "${LOG}" || { echo "FAIL: exhausted message missing"; cat "${LOG}"; exit 1; }
git -C "${WORK}" log --format=%s | grep -q "leftover commit from interrupted run" || { echo "FAIL: leftover commit missing from branch"; git -C "${WORK}" log --oneline; exit 1; }

echo "conahcnuj time-budget-leftovers flow passed"

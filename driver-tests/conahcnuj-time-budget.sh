#!/usr/bin/env bash
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

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
[{"login":"conahcnuj"}]
{"number": 15, "title": "time budget exhausted stops the run", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":124}}}}
{"number": 25}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="conahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' tb/a tb/b)" \
    MOCK_OPENCODE_TIME_BUDGET="tb/a" \
    bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

[[ ${RC} -eq 1 ]] || { echo "FAIL: exited ${RC} (expected 1)"; cat "${LOG}"; exit 1; }
grep -q "Model tb/a failed before completing the work: opencode exceeded the remaining driver time budget" "${LOG}" || { echo "FAIL: time-budget round not reported"; cat "${LOG}"; exit 1; }
grep -q "ERROR: time budget (120s) exhausted while waiting" "${LOG}" || { echo "FAIL: exhausted message missing"; cat "${LOG}"; exit 1; }
grep -q "environment error" "${LOG}" && { echo "FAIL: diagnosed as environment error"; exit 1; }
grep -q "Skipping" "${LOG}" && { echo "FAIL: provider skipped"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: no bug report"; cat "${LOG}"; exit 1; }


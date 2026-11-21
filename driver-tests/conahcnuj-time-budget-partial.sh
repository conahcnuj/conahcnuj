#!/usr/bin/env bash
# conahcnuj "time-budget round with partial commit message" test (offline).
#
# When the driver time budget runs out mid-round, the round returns instead
# of killing the process, so the caller can commit whatever partial work the
# round managed to produce (a .commit-msg the agent already wrote) before
# giving up. The partial change must reach the branch instead of being lost.
#
#   issue read -> branch -> implement (tb/a: time budget exhausted, but a
#   .commit-msg was already written) -> partial commit lands -> exit 1 (time
#   budget) -> bug report filed
#
# No secrets, no network.
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

# Simulate an agent that had already written a commit message before the
# time budget ran out.
printf 'partial commit from agent\n' > "${WORK}/.commit-msg"

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
# The partial commit message must have been consumed and committed.
grep -q "Using coding agent's commit message: partial commit from agent" "${LOG}" || { echo "FAIL: partial work was not committed"; cat "${LOG}"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: no bug report"; cat "${LOG}"; exit 1; }
# The committed message must be on the branch.
git -C "${WORK}" log --format=%s | grep -q "partial commit from agent" || { echo "FAIL: partial commit missing from branch"; git -C "${WORK}" log --oneline; exit 1; }
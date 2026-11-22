#!/usr/bin/env bash
# conahcnuj "time budget exhausted during feedback round" test (offline).
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
printf '# Guide\nFeedback fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'TAPEEOF'
[{"login":"conahcnuj"}]
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nフィードバック対応の修正。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the collected context","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"conahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
TAPEEOF
printf '{"number": 25}\n' >> "${TAPE}"

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="conahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="opencode/first" \
    MOCK_OPENCODE_TIME_BUDGET="opencode/first" \
    bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

[[ ${RC} -eq 1 ]] || { echo "FAIL: exited ${RC} (expected 1)"; cat "${LOG}"; exit 1; }
grep -q "opencode exceeded the remaining driver time budget" "${LOG}" || { echo "FAIL: time-budget round not reported"; cat "${LOG}"; exit 1; }
grep -q "ERROR: time budget (120s) exhausted while waiting" "${LOG}" || { echo "FAIL: exhausted message missing"; cat "${LOG}"; exit 1; }
! grep -q "filing a bug report" "${LOG}" || true

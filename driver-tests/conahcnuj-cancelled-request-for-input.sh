#!/usr/bin/env bash
# conahcnuj cancelled-input handling test (offline).
#
# A model round that dies because the model asked for input this
# non-interactive run cannot provide ("Cancelled a request for input this run
# cannot answer: ...", typically a Web Search confirmation) is neither an
# environment error nor a gone model: the provider works, only that model
# reached for an interactive tool. The driver must not drop the provider and
# must try the next model, and a run where every round dies this way must file
# a generic bug report rather than an environment diagnosis.
#
# Two scenarios (mirroring conahcnuj-rate-limit.sh):
#
#   1. ic/a cancelled, ic/b finishes -> provider kept, next model adopted,
#      PR created and handed to the owner for review, exit 0
#   2. every model cancelled -> run fails with a generic bug report, no
#      provider skipped, no environment diagnosis
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

TAPE_OK="${ROOT}/tape-ok.txt"
cat > "${TAPE_OK}" <<'EOF'
[{"login":"conahcnuj"}]
{"number": 15, "title": "cancelled input gives way to the next model", "body": "Cut the wait out", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":126}}}}
{}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"conahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

TAPE_BUG="${ROOT}/tape-bug.txt"
cat > "${TAPE_BUG}" <<'EOF'
[{"login":"conahcnuj"}]
{"number": 15, "title": "cancelled input gives way to the next model", "body": "Cut the wait out", "labels": [], "state": "open"}
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

LOG1="${ROOT}/run1.log"
RC1=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' ic/a ic/b)" \
    MOCK_OPENCODE_INPUT_CANCELLED="ic/a" \
    bash "${DRIVER}" 15 < "${TAPE_OK}"
) > "${LOG1}" 2>&1 || RC1=$?

[[ ${RC1} -eq 0 ]] || { echo "FAIL: scenario 1 exited ${RC1} (expected 0)"; cat "${LOG1}"; exit 1; }
grep -q "Model ic/a failed before completing the work: cancelled a request for input this run cannot answer" "${LOG1}" || { echo "FAIL: cancelled round not reported"; cat "${LOG1}"; exit 1; }
grep -q "environment error" "${LOG1}" && { echo "FAIL: cancelled input diagnosed as environment error"; exit 1; }
grep -q "Skipping" "${LOG1}" && { echo "FAIL: provider skipped on cancelled input"; exit 1; }
grep -q "Handing off session ses_mock from ic/a to ic/b" "${LOG1}" || { echo "FAIL: session not handed off"; exit 1; }
grep -q "Model ic/b completed the work" "${LOG1}" || { echo "FAIL: second model not adopted"; exit 1; }
grep -q "Created draft PR #126" "${LOG1}" || { echo "FAIL: PR not created"; exit 1; }
grep -q "Review requested on PR #126" "${LOG1}" || { echo "FAIL: review not requested"; exit 1; }

LOG2="${ROOT}/run2.log"
RC2=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' ic/a ic/b)" \
    MOCK_OPENCODE_INPUT_CANCELLED="ic/a ic/b" \
    bash "${DRIVER}" 15 < "${TAPE_BUG}"
) > "${LOG2}" 2>&1 || RC2=$?

[[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 exited ${RC2} (expected 1)"; cat "${LOG2}"; exit 1; }
grep -q "Model ic/a failed before completing the work: cancelled a request for input this run cannot answer" "${LOG2}" || { echo "FAIL: ic/a not reported"; exit 1; }
grep -q "Model ic/b failed before completing the work: cancelled a request for input this run cannot answer" "${LOG2}" || { echo "FAIL: ic/b not reported"; exit 1; }
grep -q "Skipping" "${LOG2}" && { echo "FAIL: provider skipped"; exit 1; }
grep -q "every model round died on an environment error" "${LOG2}" && { echo "FAIL: environment diagnosis printed"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG2}" || { echo "FAIL: no bug report"; exit 1; }

echo "conahcnuj cancelled-input handling passed"
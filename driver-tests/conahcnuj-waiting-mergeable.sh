#!/usr/bin/env bash
# conahcnuj "waiting for mergeable" test (offline).
#
# When GitHub reports a PR as CONFLICTING/DIRTY but the base branch is already
# an ancestor of the PR head, the driver used to wait forever for GitHub to
# recompute mergeability, even after the checks had gone green. The driver must
# wait at most once and then nudge GitHub (update-branch) instead of looping on
# the stale cache (#997). It must also re-check against the remote PR head, not
# a possibly stale local HEAD.
#
# Drives bin/conahcnuj.sh <PR> against a mocked tape whose conditions are
# CONFLICTING on the first poll and MERGEABLE on the second. The branch already
# contains its base, so the first poll waits once; the run then finishes on the
# known-good second poll.
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
git -C "${WORK}" branch -M main

git init -q --bare --initial-branch=main "${ROOT}/origin.git"
git -C "${WORK}" remote add origin "${ROOT}/origin.git"
git -C "${WORK}" push -q -u origin main

git -C "${WORK}" checkout -q -b feature/fix-10
printf 'implementation\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "implementation"
git -C "${WORK}" push -q -u origin feature/fix-10

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
[{"login":"conahcnuj"}]
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"conahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="conahcnuj/conahcnuj"

unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

if [[ ${RC} -ne 0 ]]; then
  echo "----- conahcnuj run log -----"
  cat "${LOG}"
  echo "-----------------------------"
fi

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "is a pull request; resuming it in place" "${LOG}" || { echo "FAIL: PR input was not auto-detected"; exit 1; }
grep -q "base branch 'main' already merged locally; waiting for GitHub to recompute mergeability." "${LOG}" || { echo "FAIL: the driver did not wait once for mergeability"; exit 1; }

# It must not wait twice: only one passive wait before rechecking.
WAIT_COUNT="$(grep -c "already merged locally; waiting for GitHub to recompute mergeability." "${LOG}")"
[[ "${WAIT_COUNT}" -eq 1 ]] || { echo "FAIL: expected exactly one passive wait, got ${WAIT_COUNT}"; exit 1; }

grep -q "All non-reviewer constraints pass." "${LOG}" || { echo "FAIL: constraints never passed"; exit 1; }
grep -q "Review requested on PR #15 (reviewer: conahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }


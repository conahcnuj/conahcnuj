#!/usr/bin/env bash
# conahcnuj conflict-fix-pushed (GitHub mergeability lag) test (offline).
#
# After an implementation round resolves a conflict and pushes the fix, GitHub
# may keep reporting the PR as CONFLICTING/DIRTY for a few polls while it
# recomputes mergeability. Re-running an implementation round in that window
# only re-pushes (which resets GitHub's computation again) and burns a model
# round, so the driver must instead poll and wait, keeping the "conflict fix
# already pushed" flag set, until GitHub catches up (#932, #1004).
#
# This drives bin/conahcnuj.sh <PR> against a mocked tape whose conditions stay
# CONFLICTING for several polls after the fix before becoming MERGEABLE, and
# asserts that the driver waits (more than once) instead of re-implementing.
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
git clone -q "${ROOT}/origin.git" "${ROOT}/other"
git -C "${ROOT}/other" checkout -q -B main origin/main
git -C "${ROOT}/other" config user.email "test@example.com"
git -C "${ROOT}/other" config user.name "test"
git -C "${ROOT}/other" config commit.gpgsign false
printf 'main advance\n' >> "${ROOT}/other/file.txt"
git -C "${ROOT}/other" add -A
git -C "${ROOT}/other" commit -qm "advance main"
git -C "${ROOT}/other" push -q origin main

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
[{"login":"conahcnuj"}]
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
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
  env -u GITHUB_ACTIONS CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

if [[ ${RC} -ne 0 ]]; then
  echo "----- conahcnuj run log -----"
  cat "${LOG}"
  echo "-----------------------------"
fi

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

# The driver must wait for GitHub to recompute instead of re-implementing.
WAIT_COUNT="$(grep -c "conflict fix already pushed; waiting for GitHub to recompute mergeability." "${LOG}")"
[[ "${WAIT_COUNT}" -ge 2 ]] || { echo "FAIL: expected at least 2 waits, got ${WAIT_COUNT}"; exit 1; }

IMPL_COUNT="$(grep -c "fixing with a new implementation round" "${LOG}")"
[[ "${IMPL_COUNT}" -eq 1 ]] || { echo "FAIL: expected exactly 1 implementation round, got ${IMPL_COUNT}"; exit 1; }

grep -q "Review requested on PR #15 (reviewer: conahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }

echo "conahcnuj conflict-fix-pushed passed"

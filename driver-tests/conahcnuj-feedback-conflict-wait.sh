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
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# bg\nbody", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
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
  CONAHCNUJ_MAX_SECONDS=120 env -u GITHUB_ACTIONS bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "RC=$RC"
echo "waits=$(grep -c 'conflict fix already pushed; waiting' "${LOG}")"
echo "reimpl=$(grep -c 'fixing with a new implementation round' "${LOG}")"
if [[ ${RC} -ne 0 ]]; then cat "${LOG}"; fi

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

WAIT_COUNT="$(grep -c "conflict fix already pushed; waiting for GitHub to recompute mergeability." "${LOG}" || true)"
[[ "${WAIT_COUNT}" -ge 2 ]] || { echo "FAIL: expected at least 2 waits, got ${WAIT_COUNT}"; exit 1; }

IMPL_COUNT="$(grep -c "fixing with a new implementation round" "${LOG}" || true)"
[[ "${IMPL_COUNT}" -eq 0 ]] || { echo "FAIL: expected 0 re-implementation rounds, got ${IMPL_COUNT}"; exit 1; }

grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
grep -q "Review requested on PR #15" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }

echo "conahcnuj feedback-conflict-wait passed"

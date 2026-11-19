#!/usr/bin/env bash
# collect_initial_context test (offline).
#
# The driver hands the first model round everything it can gather without
# guessing: the still-unresolved review threads of the PR being resumed (one
# mocked reviews payload) plus the orientation files of the checkout. What is
# not collectable stays out: resolved threads, files that do not exist, and
# an explicitly empty CONAHCNUJ_CONTEXT_FILES. A fresh issue has no PR, so
# no API call is made for it at all.
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run).
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
cd "${ROOT}"
printf '# Guide\nOrientation fixture README\n' > README.md
printf 'AGENTS fixture rule\n' > AGENTS.md

# Mocked reviews payload: two open threads and one resolved one. In call
# order it is the single response collect_initial_context reads for a PR.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the flag","author":{"login":"reviewer"}}]}},{"isResolved":false,"comments":{"nodes":[{"databaseId":102,"body":"And add a test","author":{"login":"reviewer"}}]}},{"isResolved":true,"comments":{"nodes":[{"databaseId":103,"body":"Already settled","author":{"login":"reviewer"}}]}}]}}}}}
EOF

export GH_API_TEST_MODE=1

# A resumed PR: open threads first, then the checkout's orientation files.
ERR="${ROOT}/err.txt"
out="$(collect_initial_context "conahcnuj" "conahcnuj" "15" < "${TAPE}" 2>"${ERR}")"
[[ "${out}" == *"Unresolved review threads on PR #15:"* ]] || { echo "FAIL: the open threads have no heading"; exit 1; }
[[ "${out}" == *"- [comment 101 by reviewer] Please document the flag"* ]] || { echo "FAIL: the first open thread was not collected"; exit 1; }
[[ "${out}" == *"- [comment 102 by reviewer] And add a test"* ]] || { echo "FAIL: the second open thread was not collected"; exit 1; }
[[ "${out}" != *"Already settled"* ]] || { echo "FAIL: a resolved thread was collected"; exit 1; }
# Orientation files are no longer collected by default (too much noise); only the
# unresolved review threads ride along for a resumed PR.
[[ "${out}" != *"README.md:"* ]] || { echo "FAIL: README.md was collected by default"; exit 1; }
[[ "${out}" != *"AGENTS.md:"* ]] || { echo "FAIL: AGENTS.md was collected by default"; exit 1; }
grep -q "Collected context up front: unresolved review threads of PR #15" "${ERR}" || { echo "FAIL: the run log does not say what was collected"; cat "${ERR}" >&2; exit 1; }

# A resumed PR whose review decision is null (the reviewer is mid-review and
# has an unsubmitted review): unresolved threads from existing reviews are
# still collected as work to do, so they can be addressed instead of waiting
# for the unsubmitted review (issue #989).
TAPE_NULL="${ROOT}/tape-null.txt"
cat > "${TAPE_NULL}" <<'EOF'
{"data":{"repository":{"pullRequest":{"reviewDecision":null,"reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":201,"body":"Please write tests","author":{"login":"reviewer"}}]}}]}}}}}
EOF
out="$(collect_initial_context "conahcnuj" "conahcnuj" "15" < "${TAPE_NULL}" 2>"${ERR}")"
[[ "${out}" == *"Unresolved review threads on PR #15:"* ]] || { echo "FAIL: a null review decision did not collect review threads"; exit 1; }
[[ "${out}" == *"- [comment 201 by reviewer] Please write tests"* ]] || { echo "FAIL: a null review decision did not collect the thread body"; exit 1; }
grep -q "Collected context up front: unresolved review threads of PR #15" "${ERR}" || { echo "FAIL: the run log does not say what was collected"; cat "${ERR}" >&2; exit 1; }
# A fresh issue has no PR to read threads from: the same payload would have
# produced them above, so its absence proves no API call was made.
out="$(collect_initial_context "conahcnuj" "conahcnuj" "" < "${TAPE}" 2>/dev/null)"
[[ "${out}" != *"Unresolved review threads"* ]] || { echo "FAIL: an issue was treated as a PR"; exit 1; }
# No orientation files are collected by default, so a fresh issue collects nothing.
[[ -z "${out}" ]] || { echo "FAIL: expected nothing to collect for a fresh issue, got: ${out}"; exit 1; }

# CONAHCNUJ_CONTEXT_FILES narrows the list to what the run actually wants.
printf 'Notes fixture\n' > NOTES.md
export CONAHCNUJ_CONTEXT_FILES="NOTES.md"
out="$(collect_initial_context "conahcnuj" "conahcnuj" "" < /dev/null 2>/dev/null)"
[[ "${out}" == *"Notes fixture"* ]] || { echo "FAIL: the configured file was not collected"; exit 1; }
[[ "${out}" != *"README.md:"* ]] || { echo "FAIL: the default files were collected despite the override"; exit 1; }

# An explicitly empty value sends no files at all (and so does an unset one now,
# since the default list is empty).
export CONAHCNUJ_CONTEXT_FILES=""
out="$(collect_initial_context "conahcnuj" "conahcnuj" "" < /dev/null 2>/dev/null)"
[[ -z "${out}" ]] || { echo "FAIL: empty CONAHCNUJ_CONTEXT_FILES still collected files"; exit 1; }
unset CONAHCNUJ_CONTEXT_FILES

# Nothing to collect: no PR, no files. The prompt then carries the issue alone.
rm -f README.md AGENTS.md NOTES.md
out="$(collect_initial_context "conahcnuj" "conahcnuj" "" < /dev/null 2>/dev/null)"
[[ -z "${out}" ]] || { echo "FAIL: expected nothing to collect, got: ${out}"; exit 1; }

echo "collect_initial_context passed"

#!/usr/bin/env bash
# Reproduction tests for "printf: write error: Broken pipe" (issue #940):
# when a consumer of a gh-api helper's stdout closes the pipe early, every
# write must be swallowed by the 2>/dev/null || true guards instead of
# leaking the error or failing the caller under `set -o pipefail`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/gh-api.sh
. "${REPO}/lib/gh-api.sh"

export GH_API_TEST_MODE=1

make_large_reviews() {
  python3 - "$1" <<'PY'
import json, sys
n = int(sys.argv[1])
comments = [{"databaseId": i, "body": "comment %d" % i, "author": {"login": "reviewer"}} for i in range(n)]
nodes = [{"isResolved": False, "comments": {"nodes": comments}}]
obj = {"data": {"repository": {"pullRequest": {"reviewDecision": "CHANGES_REQUESTED", "reviewThreads": {"nodes": nodes}}}}}
print(json.dumps(obj))
PY
}

# We'll inline each test instead of a generic helper.

# review_summary (node path when node is present, awk fallback otherwise).
test_sigpipe_review_summary() {
  local json errfile status
  json="$(make_large_reviews 2000)"
  errfile="$(mktemp)"
  set +e
  printf '%s\n' "${json}" | gh_api_review_summary 2>"${errfile}" | true
  status=${PIPESTATUS[0]}
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "FAIL (review_summary): helper exited ${status}" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  if grep -q "Broken pipe" "${errfile}"; then
    echo "FAIL (review_summary): 'Broken pipe' leaked to stderr" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  rm -f "${errfile}"
}

test_sigpipe_unresolved_threads() {
  local json errfile status
  json="$(make_large_reviews 2000)"
  errfile="$(mktemp)"
  set +e
  printf '%s\n' "${json}" | gh_api_unresolved_threads 2>"${errfile}" | true
  status=${PIPESTATUS[0]}
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "FAIL (unresolved_threads): helper exited ${status}" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  if grep -q "Broken pipe" "${errfile}"; then
    echo "FAIL (unresolved_threads): 'Broken pipe' leaked to stderr" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  rm -f "${errfile}"
}

test_sigpipe_review_fingerprint() {
  local json errfile status
  json="$(make_large_reviews 2000)"
  errfile="$(mktemp)"
  set +e
  gh_api_review_fingerprint "${json}" 2>"${errfile}" | true
  status=${PIPESTATUS[0]}
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "FAIL (review_fingerprint): helper exited ${status}" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  if grep -q "Broken pipe" "${errfile}"; then
    echo "FAIL (review_fingerprint): 'Broken pipe' leaked to stderr" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  rm -f "${errfile}"
}

test_sigpipe_repo_admins() {
  local json errfile status
  json="$(python3 -c 'import json; print(json.dumps([{"login":"u%d"%i} for i in range(2000)]))')"
  errfile="$(mktemp)"
  set +e
  printf '%s\n' "${json}" | gh_api_repo_admins conahcnuj conahcnuj 2>"${errfile}" | true
  status=${PIPESTATUS[0]}
  set -e
  if [[ ${status} -ne 0 ]]; then
    echo "FAIL (repo_admins): helper exited ${status}" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  if grep -q "Broken pipe" "${errfile}"; then
    echo "FAIL (repo_admins): 'Broken pipe' leaked to stderr" >&2
    cat "${errfile}" >&2
    rm -f "${errfile}"; exit 1
  fi
  rm -f "${errfile}"
}

test_sigpipe_review_summary
test_sigpipe_unresolved_threads
test_sigpipe_review_fingerprint
test_sigpipe_repo_admins

echo "All sigpipe tests passed"

#!/usr/bin/env bash
# conahcnuj driver gh auth E2E test (offline).
#
# The driver must hand the coding agent an environment in which `gh auth
# status` succeeds as the GitHub App (issue #964). This drives the real
# bin/conahcnuj.sh state machine against a mocked GitHub API tape, but unlike
# the other flow tests it leaves OPENCODE_TEST_MODE off: opencode_run takes its
# real execution path and the fake `opencode` on PATH inherits the exported
# GH_TOKEN/GITHUB_TOKEN. The fake agent runs `gh auth status` before writing its
# change, with a fake `gh` that only succeeds when both names hold the App
# installation token staged for this test.
#
# The driver tree is copied to a temp dir so get-token.sh reads a staged
# token.cache instead of the real app.env / private key. No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
FAKE_BIN="${ROOT}/fakebin"
DRIVER_ROOT="${ROOT}/driver"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}" "${FAKE_BIN}" "${DRIVER_ROOT}/bin" "${DRIVER_ROOT}/lib" "${DRIVER_ROOT}/gh-app"

# A standalone copy of the driver source: lib/opencode.sh resolves gh-app/
# relative to itself, so the staged token.cache below is the one used.
cp "${REPO}"/bin/* "${DRIVER_ROOT}/bin/"
cp "${REPO}"/lib/* "${DRIVER_ROOT}/lib/"
cp "${REPO}"/gh-app/*.sh "${REPO}"/gh-app/app.env.example "${REPO}"/gh-app/missing-models \
  "${DRIVER_ROOT}/gh-app/"
cat > "${DRIVER_ROOT}/gh-app/app.env" <<'EOF'
APP_ID=1
INSTALLATION_ID=12345
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/nonexistent.pem
BASH_EXE=/bin/bash
EOF
printf '%s|%s\n' "$(( $(date +%s) + 3600 ))" "ghs_test_app" > "${DRIVER_ROOT}/gh-app/token.cache"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# The fake gh only authenticates when the driver exported the App token under
# both names. It records the outcome outside the worktree so the driver's
# test-mode commit cannot pick it up.
export GH_AUTH_RESULT_FILE="${ROOT}/gh-auth-result"
export GH_AUTH_STDOUT_FILE="${ROOT}/gh-auth-stdout"
cat > "${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
result="${GH_AUTH_RESULT_FILE:?}"
if [[ "${GH_TOKEN:-}" == "ghs_test_app" && "${GITHUB_TOKEN:-}" == "ghs_test_app" ]]; then
  printf 'Logged in to github.com account conahcnuj[bot]\n'
  printf 'OK GH_TOKEN=%s GITHUB_TOKEN=%s\n' "${GH_TOKEN}" "${GITHUB_TOKEN}" > "${result}"
  exit 0
fi
printf 'FAIL GH_TOKEN=%s GITHUB_TOKEN=%s\n' "${GH_TOKEN:-<unset>}" "${GITHUB_TOKEN:-<unset>}" > "${result}"
printf 'The token in GH_TOKEN is invalid.\n' >&2
exit 1
EOF
chmod +x "${FAKE_BIN}/gh"

# A fake agent: answer the version probe, run `gh auth status` with the env
# the driver gave us, then leave the usual mock change + commit message.
cat > "${FAKE_BIN}/opencode" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf '1.19.5\n'
  exit 0
fi
if [[ "${1:-}" == "models" ]]; then
  printf 'opencode/first\n'
  exit 0
fi
gh auth status > "${GH_AUTH_STDOUT_FILE:?}" 2>&1
printf '{"type":"text","text":"gh auth checked"}\n'
printf 'mock change from gh-auth E2E\n' >> conahcnuj.mock
printf 'mock commit from gh-auth E2E\n' > .commit-msg
exit 0
EOF
chmod +x "${FAKE_BIN}/opencode"

# API tape: enough to create the draft PR, pass the conditions poll and hand
# the PR to the reviewer. GITHUB_ACTIONS=true ends the run at that hand-off.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
[{"login":"conahcnuj"}]
{"number": 10, "title": "gh auth E2E", "body": "Check gh auth status.", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="conahcnuj/conahcnuj"
# Deliberately keep OPENCODE_TEST_MODE off: the fake opencode must be executed
# by opencode_run's real path so it inherits the exported token env.
unset OPENCODE_TEST_MODE
export PATH="${FAKE_BIN}:${PATH}"
unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL OPENCODE_VERSION_CACHE

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  GITHUB_ACTIONS=true CONAHCNUJ_MAX_SECONDS=30 \
    bash "${DRIVER_ROOT}/bin/conahcnuj.sh" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

if [[ ${RC} -ne 0 ]]; then
  echo "----- conahcnuj gh-auth E2E run log -----"
  cat "${LOG}"
  echo "----------------------------------------"
fi
[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

[[ -f "${GH_AUTH_RESULT_FILE}" ]] || { echo "FAIL: the agent never ran gh auth status"; exit 1; }
cat "${GH_AUTH_RESULT_FILE}"
grep -q '^OK GH_TOKEN=ghs_test_app GITHUB_TOKEN=ghs_test_app$' "${GH_AUTH_RESULT_FILE}" || {
  echo "FAIL: gh auth status did not see both exported App token names"
  exit 1
}
grep -q 'Logged in to github.com account conahcnuj\[bot\]' "${GH_AUTH_STDOUT_FILE}" || {
  echo "FAIL: gh auth status did not authenticate as the bot"
  exit 1
}
grep -q "Model opencode/first completed the work" "${LOG}" || {
  echo "FAIL: the agent round did not finish"
  exit 1
}

echo "conahcnuj driver gh auth E2E passed"

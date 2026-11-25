#!/usr/bin/env bash
# conahcnuj signal-killed round test (offline).
#
# The agent on an issue may run `pkill -f ...` (or the CI runner may time the
# step out), which terminates the opencode process with a signal. That is an
# external interruption of the run, not a driver defect: the driver must stop
# cleanly with a signal exit code and must not file a "failed to resolve"
# bug report for it (#1025). Before the fix such a round was an unclassified
# failure, every model was burned through and the run exited 1 with a bug
# report whose log only showed the agent's command being killed.
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

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
[{"login":"conahcnuj"}]
{"number": 15, "title": "signal killed round stops the run", "body": "dummy body", "labels": [], "state": "open"}
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
    MOCK_OPENCODE_MODELS="$(printf '%s\n' sig/a sig/b)" \
    MOCK_OPENCODE_SIGNAL_KILLED="sig/a" \
    bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- a signal-killed round -----"
cat "${LOG}"
echo "---------------------------------"

# 143 (SIGTERM) is an interruption, so the bug-report carve-out must apply.
[[ ${RC} -eq 143 ]] || { echo "FAIL: exited ${RC} (expected 143)"; exit 1; }
grep -q "Model sig/a failed before completing the work: opencode was terminated by a signal" "${LOG}" || { echo "FAIL: signal-killed round not reported"; exit 1; }
grep -q "Interrupted (exit 143); not filing a bug report" "${LOG}" || { echo "FAIL: run did not stop as an interruption"; exit 1; }
! grep -q "Bug report issue" "${LOG}" || { echo "FAIL: a signal kill filed a bug report"; exit 1; }
# The second model must not be tried: an external kill affects the whole run.
! grep -q "Handing off session" "${LOG}" || { echo "FAIL: a signal kill handed off to another model"; exit 1; }

echo "conahcnuj signal-killed round passed"

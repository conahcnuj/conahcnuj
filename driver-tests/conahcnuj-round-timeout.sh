#!/usr/bin/env bash
# A model round must receive every second the driver has left, not an
# artificial one-second run when the 30-second safety margin is used up.
#
# The old calculation subtracted 30 seconds from the remaining budget and
# floored the result at one second. Once a long first round left 30 seconds or
# less, every later model was launched with a one-second timeout, produced
# nothing, and the run filed a misleading "no model completed the work" report
# (issue #980). Each round now gets the real remaining budget; the driver's
# check_timeout still stops the loop when the budget is actually gone.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
WORK="${ROOT}/repo"
mkdir -p "${WORK}"
git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init >/dev/null

# Keep the clock in this process: implement() reads date +%s for both the
# budget check and the per-round timeout, so a fake clock makes the assertion
# deterministic without sleeping.
FAKE_NOW=1000
date() { printf '%s\n' "${FAKE_NOW}"; }

export CONAHCNUJ_IMPORT=1
export CONAHCNUJ_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export GH_API_TEST_MODE=1
export CONAHCNUJ_REPO=conahcnuj/conahcnuj
export CONAHCNUJ_MAX_SECONDS=60
export MOCK_OPENCODE_MODELS="prov/one
prov/two"

# shellcheck source=bin/conahcnuj.sh
source "${REPO}/bin/conahcnuj.sh"

# Capture the timeout handed to each round. The first round starts with the
# whole budget; make it consume 35 seconds so the second round must receive
# the remaining 25 seconds instead of a meaningless one-second retry.
calls=0
timeouts=()
opencode_run() {
  calls=$((calls + 1))
  timeouts+=("${CONAHCNUJ_RUN_TIMEOUT_SECONDS:-}")
  if [[ ${calls} -eq 1 ]]; then
    FAKE_NOW=$((FAKE_NOW + 35))
  fi
  return 1
}

cd "${WORK}"
rc=0
implement "Issue title" "Issue body" "" "" >/dev/null 2>&1 || rc=$?

[[ ${rc} -ne 0 ]] || { echo "FAIL: implement unexpectedly succeeded"; exit 1; }
[[ ${calls} -eq 2 ]] || { echo "FAIL: expected two model rounds, got ${calls}"; exit 1; }
[[ "${timeouts[0]}" == "60" ]] || { echo "FAIL: first round got ${timeouts[0]}, expected 60"; exit 1; }
[[ "${timeouts[1]}" == "25" ]] || { echo "FAIL: second round got ${timeouts[1]}, expected the remaining 25 seconds"; exit 1; }

echo "conahcnuj round timeout passed"

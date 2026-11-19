#!/usr/bin/env bash
# Offline tests for the "already-answered review thread" behaviour: an
# unresolved thread whose last comment is by the bot must still be surfaced
# (with the bot comment and its author) so the agent can edit that comment
# instead of posting a duplicate reply. (#983)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/gh-api.sh
. "${REPO}/lib/gh-api.sh"

export GH_API_TEST_MODE=1

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

python3 - "${TMP}/answered.json" <<'PY'
import json, sys
payload = {
  "data": {"repository": {"pullRequest": {
    "reviewDecision": "CHANGES_REQUESTED",
    "reviews": {"nodes": []},
    "comments": {"nodes": []},
    "reviewThreads": {"nodes": [{
      "isResolved": False,
      "comments": {"nodes": [
        {"databaseId": 201, "body": "Please fix the typo", "author": {"login": "reviewer"}},
        {"databaseId": 202, "body": "Fixed in abc123", "author": {"login": "conahcnuj[bot]"}},
      ]}
    }]}
  }}}
}
with open(sys.argv[1], "w") as f:
    json.dump(payload, f)
PY

# review_summary keeps the bot-authored comment and its author.
summary="$(gh_api_review_summary < "${TMP}/answered.json")"
[[ "${summary}" == *"REVIEW THREADS (unresolved):"* ]] || { echo "FAIL: no review threads section"; exit 1; }
[[ "${summary}" == *"[comment 201 by reviewer] Please fix the typo"* ]] || { echo "FAIL: reviewer comment missing"; exit 1; }
[[ "${summary}" == *"[comment 202 by conahcnuj[bot]] Fixed in abc123"* ]] || { echo "FAIL: bot comment missing"; exit 1; }

# unresolved_threads (used for context and TODO seeding input) keeps them too.
threads="$(gh_api_unresolved_threads < "${TMP}/answered.json")"
[[ "${threads}" == *"[comment 202 by conahcnuj[bot]] Fixed in abc123"* ]] || { echo "FAIL: bot comment missing from unresolved threads"; exit 1; }

# A thread that is still open but only has a bot comment is still surfaced.
python3 - "${TMP}/botonly.json" <<'PY'
import json, sys
payload = {
  "data": {"repository": {"pullRequest": {
    "reviewDecision": "CHANGES_REQUESTED",
    "reviews": {"nodes": []},
    "comments": {"nodes": []},
    "reviewThreads": {"nodes": [{
      "isResolved": False,
      "comments": {"nodes": [
        {"databaseId": 301, "body": "Already answered", "author": {"login": "conahcnuj[bot]"}},
      ]}
    }]}
  }}}
}
with open(sys.argv[1], "w") as f:
    json.dump(payload, f)
PY
threads2="$(gh_api_unresolved_threads < "${TMP}/botonly.json")"
[[ "${threads2}" == *"[comment 301 by conahcnuj[bot]] Already answered"* ]] || { echo "FAIL: bot-only thread missing"; exit 1; }

echo "All review-answered-thread tests passed"
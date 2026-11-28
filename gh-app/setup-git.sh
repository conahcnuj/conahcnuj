#!/usr/bin/env bash
# Configure the current git repository to operate as the GitHub App.
# Settings (APP_ID, APP_SLUG, BASH_EXE, ...) are read from app.env.
# Run from inside the repository root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/app.env"

# Real config wins; fall back to the committed example (e.g. fresh clone / CI).
if [[ ! -f "${ENV_FILE}" && -f "${HERE}/app.env.example" ]]; then
  ENV_FILE="${HERE}/app.env.example"
fi

set -a
# shellcheck source=gh-app/app.env.example
. "${ENV_FILE}"
set +a

# App slug: app.env value wins, otherwise auto-resolved from the API.
APP_SLUG="$(bash "${HERE}/app-slug.sh")"
export APP_SLUG
# Bot user ID: app.env value wins, otherwise auto-resolved from the API.
BOT_USER_ID="$(bash "${HERE}/bot-user-id.sh")"
BOT_NAME="${APP_SLUG}[bot]"
BOT_EMAIL="${BOT_USER_ID}+${APP_SLUG}[bot]@users.noreply.github.com"

HELPER="${HERE}/git-credential-helper.sh"
API_COMMIT="${HERE}/api-commit.sh"
BASH_EXE="${BASH_EXE:-C:/Program Files/Git/bin/bash.exe}"
HELPER_CMD="!\"${BASH_EXE}\" \"${HELPER//\\//}\""
API_COMMIT_CMD="!\"${BASH_EXE}\" \"${API_COMMIT//\\//}\""

SCOPE="--local"
# `git config --local` is only valid inside a git repository. Detect that by
# asking git itself instead of peeking at a `.git` entry: a directory or file
# named `.git` that does not point at a real repository (a stale checkout
# remnant, a half-initialized tree, ...) makes the old `[[ ! -d .git ]]` test
# believe we are inside a repo, so `--local` was used and failed with
# "fatal: --local can only be used inside a git repository" (exit 128). Falling
# back to `--global` keeps the run going; move out of the broken tree first so
# git does not keep trying to resolve the invalid `.git` while writing the
# global config.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: not inside a git repository; applying to --global instead." >&2
  SCOPE="--global"
  cd /
fi

git config "${SCOPE}" user.name "${BOT_NAME}"
git config "${SCOPE}" user.email "${BOT_EMAIL}"
git config "${SCOPE}" credential.helper "${HELPER_CMD}"
git config "${SCOPE}" commit.gpgsign false
# `git vc` is the verified-commit alias (see plugins/gh-app-token.ts). Mirror it
# into the (local or global) git config so it is available in every shell,
# not only inside an opencode session whose plugin injects it via GIT_CONFIG_*.
git config "${SCOPE}" alias.vc "${API_COMMIT_CMD}"

if [[ "${CONAHCNUJ_SETUP_GIT_VERBOSE:-0}" == "1" ]]; then
  echo "Configured (${SCOPE}):"
  git config ${SCOPE} --get-regexp "^(user\.(name|email)|credential\.helper|commit\.gpgsign|alias\.vc)$" 2>/dev/null || true
  echo
  echo "Test with: git ls-remote https://github.com/<owner>/<repo>.git HEAD"
fi
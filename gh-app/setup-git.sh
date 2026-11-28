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
# back to `--global` keeps the run going. `git config --global` does not
# need a repository (it writes ~/.gitconfig), so we stay in the current
# directory instead of jumping to "/" (which only obscured the caller's cwd
# and never helped git resolve anything). Staying put keeps the caller's cwd
# intact and avoids touching the (possibly broken) working tree.
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: not inside a git repository; applying to --global instead." >&2
  SCOPE="--global"
fi

apply_scope() {
  local scope="$1"
  git config "${scope}" user.name "${BOT_NAME}" &&
  git config "${scope}" user.email "${BOT_EMAIL}" &&
  git config "${scope}" credential.helper "${HELPER_CMD}" &&
  git config "${scope}" commit.gpgsign false &&
  git config "${scope}" alias.vc "${API_COMMIT_CMD}"
}

# `git vc` is the verified-commit alias (see plugins/gh-app-token.ts). Mirror it
# into the (local or global) git config so it is available in every shell,
# not only inside an opencode session whose plugin injects it via GIT_CONFIG_*.
# If the chosen (local) scope turns out to be unusable even though detection
# passed, fall back to --global instead of aborting the run with exit 128.
if [[ "${SCOPE}" == "--local" ]] && ! apply_scope "${SCOPE}"; then
  echo "WARNING: local git config failed; applying to --global instead." >&2
  SCOPE="--global"
fi
apply_scope "${SCOPE}"

if [[ "${CONAHCNUJ_SETUP_GIT_VERBOSE:-0}" == "1" ]]; then
  echo "Configured (${SCOPE}):"
  git config ${SCOPE} --get-regexp "^(user\.(name|email)|credential\.helper|commit\.gpgsign|alias\.vc)$" 2>/dev/null || true
  echo
  echo "Test with: git ls-remote https://github.com/<owner>/<repo>.git HEAD"
fi
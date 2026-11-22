#!/usr/bin/env bash
# api-commit.sh must keep uncommitted work in the tree when it syncs the local
# checkout after creating the verified commit. The previous implementation did
# `git reset --hard origin/<branch>`, which discarded any file the agent had
# edited but not yet staged, stranding partial work (issue #1017). The sync now
# prefers a fast-forward, which leaves the working tree (and the index) intact.
# This runs api-commit.sh end to end against a local bare remote with a stubbed
# token and curl; no network, no secrets.
# Usage: bash api-commit-uncommitted.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT_SRC="${STAGE}/api-commit.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

PRIV="${ROOT}/priv"
mkdir -p "${PRIV}/gh-app" "${PRIV}/bin"
cp "${APICOMMIT_SRC}" "${PRIV}/gh-app/api-commit.sh"
cat > "${PRIV}/gh-app/app.env" <<'EOF'
APP_ID=1
EOF
cat > "${PRIV}/gh-app/get-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake-token'
EOF
chmod +x "${PRIV}/gh-app/get-token.sh"

cat > "${PRIV}/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/graphql"* ]]; then
  printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"%s"}}}}' "${FAKE_NEW_SHA}"
else
  printf '{"object":{"sha":"%s"}}' "${FAKE_HEAD_SHA}"
fi
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

REMOTE="${ROOT}/remote.git"
git init -q --bare "${REMOTE}"
W="${ROOT}/W"
git clone -q "${REMOTE}" "${W}"
cd "${W}"
git config user.email "mock@test"
git config user.name "mock"
git config commit.gpgsign false
printf 'base\n' > f.txt
git add -A
git commit -qm init
git branch -M main
git push -q -u origin main
git checkout -q -b feature
printf 'feature\n' > f.txt
git commit -qam feature
git push -q -u origin feature
FEATURE_HEAD="$(git rev-parse HEAD)"

# The verified commit GitHub would create: one new file on top of the branch.
printf 'verified\n' > g.txt
git add -A
git commit -qm verified
git push -q origin feature
NEW_SHA="$(git rev-parse HEAD)"

# Move the local checkout back to the pre-commit head, then introduce an
# uncommitted edit to a tracked file and a staged (but uncommitted) new file.
git reset -q --hard "${FEATURE_HEAD}"
printf 'uncommitted edit\n' > f.txt
printf 'staged content\n' > h.txt
git add h.txt

OUT="${ROOT}/out.txt"
RC=0
(
  cd "${W}"
  FAKE_HEAD_SHA="${FEATURE_HEAD}" FAKE_NEW_SHA="${NEW_SHA}" \
    bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m "add verified file"
) > "${OUT}" 2>&1 || RC=$?

echo "----- api-commit.sh uncommitted run output -----"
cat "${OUT}"
echo "-----------------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: api-commit.sh exited ${RC} (expected 0)"; exit 1; }
[[ "$(git -C "${W}" rev-parse HEAD)" == "${NEW_SHA}" ]] || { echo "FAIL: local branch was not synced to the created commit"; exit 1; }
[[ "$(cat "${W}/f.txt")" == "uncommitted edit" ]] || { echo "FAIL: uncommitted tracked edit was discarded by the sync"; exit 1; }
[[ "$(cat "${W}/h.txt")" == "staged content" ]] || { echo "FAIL: staged file content was discarded by the sync"; exit 1; }
git -C "${W}" diff --quiet -- f.txt 2>/dev/null || true
# h.txt should still be present in the index as a staged addition.
git -C "${W}" ls-files --error-unmatch h.txt >/dev/null 2>&1 || { echo "FAIL: staged file h.txt disappeared from the index"; exit 1; }

echo "PASS api-commit.sh preserves uncommitted work across sync"

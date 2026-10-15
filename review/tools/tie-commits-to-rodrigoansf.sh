#!/bin/bash
# Put Rodrigoansf on the commits written in the stack-PR review, then force-push (with lease).
#
#   usage: tie-commits-to-rodrigoansf.sh <horses3d-gpu clone> <horses3d clone>
#
# Both clones must have the forks (Rodrigoansf/horses3d-gpu, Rodrigoansf/horses3d) as 'origin'.
# - Commits authored by Claude: author and committer become Rodrigoansf.
# - Cherry-picked commits (zalbanob): author kept, committer becomes Rodrigoansf.
# - The 'Co-Authored-By: Claude ...' line is removed from every commit message.
# File contents are not changed: each branch's tree is checked before pushing.
# Also sets user.name/user.email in both clones for future commits.
set -euo pipefail
GPU=$(cd "$1" && pwd); LEGACY=$(cd "$2" && pwd)
NAME="Rodrigoansf"; EMAIL="rodrigoansf@gmail.com"
F=$(mktemp)
cat > "$F" <<EOF
if [ "\$GIT_AUTHOR_EMAIL" = "noreply@anthropic.com" ]; then
  export GIT_AUTHOR_NAME="$NAME" GIT_AUTHOR_EMAIL="$EMAIL"
fi
export GIT_COMMITTER_NAME="$NAME" GIT_COMMITTER_EMAIL="$EMAIL"
EOF
export FILTER_BRANCH_SQUELCH_WARNING=1

rewrite() {  # rewrite <branch> <exclude-refs...>
  local b=$1; shift
  git rev-parse -q --verify "refs/heads/$b" > /dev/null || git branch "$b" "origin/$b"
  local old; old=$(git rev-parse "$b")
  [ "$old" = "$(git rev-parse "origin/$b")" ] || { echo "$b differs from origin/$b, not touching it"; exit 1; }
  git filter-branch -f --env-filter ". $F" --msg-filter "sed '/^Co-Authored-By: Claude/d'" -- "$@" "$b" > /dev/null
  [ "$(git rev-parse "$old^{tree}")" = "$(git rev-parse "$b^{tree}")" ] || { echo "TREE CHANGED on $b, not pushing"; exit 1; }
  git push --force-with-lease="$b:$old" origin "$b"
  echo "done $b: $(git log -1 --format='%an | %cn' "$b")"
}

# The forks' develop / GMM_develop / upstream-master are identical to upstream's bases.
cd "$GPU"
git fetch origin
git config user.name "$NAME"; git config user.email "$EMAIL"
for b in fix/minor-develop fix/minor-GMM fix/aliasing-sensor-realloc \
         change/strong-form-split-fluxes change/svv-energy-divv \
         change/te-sensor-source-term change/limiter-pressure-reference \
         claude/eager-lamport-ymhyjk; do
  rewrite "$b" ^origin/develop ^origin/GMM_develop
done

cd "$LEGACY"
git fetch origin
git config user.name "$NAME"; git config user.email "$EMAIL"
for b in legacy/minor-fixes legacy/te-sensor-source-term legacy/svv-energy-divv \
         legacy/limiter-pressure-reference legacy/aliasing-sensor-realloc; do
  rewrite "$b" ^origin/upstream-master
done
rm -f "$F"

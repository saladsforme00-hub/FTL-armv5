#!/usr/bin/env bash
# Keep <owner>/pi-hole (your fork of pi-hole/pi-hole) at the latest upstream
# release, with the ARMv5 patch on top.
#
# Pi-hole's updater does `git pull` and then `git reset --hard <latest tag>`,
# so the fork has to carry *its own* tag for each release, pointing at the
# patched commit. This script:
#   --init : rebuilds the fork's master as <latest upstream tag> + patch and
#            pushes it with the tag. Run once before installing; run again
#            after refreshing the patch if a merge ever conflicts (a re-init
#            is recorded as a merge, so installed devices still fast-forward).
#   (none) : merges the newest upstream release tag into the fork's master
#            (a normal merge, never a rewrite, so devices can fast-forward),
#            re-tags it with the upstream tag name and pushes.
# It exits non-zero (and pushes nothing) if the merge conflicts or the patch
# disappeared, so a broken upstream change can never reach your Pi-hole.
#
# Usage: sync-core-fork.sh <fork-owner> [--init] [--tag vX.Y.Z]
# Env:   GH_TOKEN      token with Contents+Workflows write on <owner>/pi-hole
#        FORK_URL      override push URL (default: GitHub, using GH_TOKEN)
#        UPSTREAM_URL  default https://github.com/pi-hole/pi-hole.git
#        PATCH         default: ../core-patch/0001-armv5-support.patch
#        DRY_RUN=1     do everything except push
set -euo pipefail

OWNER="${1:?usage: $0 <fork-owner> [--init] [--tag vX.Y.Z]}"; shift
INIT=0; TAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) INIT=1;;
    --tag) TAG="$2"; shift;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac; shift
done

HERE="$(dirname "$(realpath "$0")")"
PATCH="$(realpath "${PATCH:-$HERE/../core-patch/0001-armv5-support.patch}")"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/pi-hole/pi-hole.git}"
if [[ -z "${FORK_URL:-}" ]]; then
  FORK_URL="https://github.com/${OWNER}/pi-hole.git"
  [[ -n "${GH_TOKEN:-}" ]] && FORK_URL="https://x-access-token:${GH_TOKEN}@github.com/${OWNER}/pi-hole.git"
fi

WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"
git init -q -b master repo && cd repo
git config user.name  "${GIT_AUTHOR_NAME:-pihole-armv5-bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-pihole-armv5-bot@users.noreply.github.com}"
git remote add origin "$FORK_URL"
git remote add upstream "$UPSTREAM_URL"
git fetch -q origin '+refs/heads/master:refs/remotes/origin/master' '+refs/tags/*:refs/tags/*' || true
# Upstream tags go to their own namespace so they never collide with ours
git fetch -q --no-tags upstream '+refs/tags/*:refs/upstream-tags/*' '+refs/heads/master:refs/remotes/upstream/master'

if [[ -z "$TAG" ]]; then
  # Latest release = highest vX.Y[.Z] tag reachable from upstream master
  TAG="$(git for-each-ref --format='%(refname:strip=2)' --sort=-v:refname 'refs/upstream-tags/v*' \
        | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | while read -r t; do git merge-base --is-ancestor "refs/upstream-tags/$t" upstream/master && { echo "$t"; break; }; done)"
fi
[[ -n "$TAG" ]] || { echo "could not determine upstream release tag" >&2; exit 1; }
echo "Upstream release: $TAG"

patch_present() { git grep -q 'PIHOLE_FORK_OWNER=' "$1" -- 'automated install/basic-install.sh'; }

verify_tree() {
  bash -n 'automated install/basic-install.sh'
  bash -n advanced/Scripts/update.sh
  grep -q "PIHOLE_FORK_OWNER=\"${OWNER}\"" 'automated install/basic-install.sh'
  grep -q 'l_binary="pihole-FTL-armv5"' 'automated install/basic-install.sh'
  grep -q "github.com/${OWNER}/pi-hole.git" advanced/Scripts/update.sh
}

if [[ $INIT -eq 0 ]] && ! git rev-parse -q --verify origin/master >/dev/null; then
  echo "fork has no master branch; use --init" >&2; exit 1
fi
if [[ $INIT -eq 0 ]] && ! patch_present origin/master; then
  echo "fork master doesn't carry the ARMv5 patch yet; run once with --init" >&2; exit 1
fi

if [[ $INIT -eq 1 ]]; then
  git checkout -q -B master "refs/upstream-tags/$TAG"
  sed "s/__FORK_OWNER__/${OWNER}/g" "$PATCH" | git apply --3way --whitespace=nowarn
  verify_tree
  git commit -qam "ARMv5: install FTL from ${OWNER}/FTL-armv5, update from ${OWNER}/pi-hole" \
      -m "Based on upstream ${TAG}."
  PUSH_FORCE=1
  if git rev-parse -q --verify origin/master >/dev/null && patch_present origin/master; then
    # Re-init of a fork that devices already track: keep history
    # fast-forwardable by recording the rebuilt tree as a merge on top of the
    # old master (same idea as `git merge -s ours`, but taking *our* new tree).
    rebuilt="$(git commit-tree "HEAD^{tree}" -p origin/master -p HEAD \
                 -m "Rebuild ARMv5 patch on upstream ${TAG}")"
    git reset -q --hard "$rebuilt"
    PUSH_FORCE=0
  fi
else
  if git merge-base --is-ancestor "refs/upstream-tags/$TAG" origin/master \
     && [[ "$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)" == "$(git rev-parse origin/master)" ]]; then
    echo "Fork is already at $TAG. Nothing to do."; exit 0
  fi
  git checkout -q -B master origin/master
  if ! git merge -q --no-ff --no-edit -m "Merge upstream ${TAG}" "refs/upstream-tags/$TAG"; then
    git merge --abort || true
    echo "::error::Merging upstream ${TAG} into the fork conflicts with the ARMv5 patch. Refresh core-patch/0001-armv5-support.patch against upstream ${TAG}, then run this script with --init (history stays fast-forward for installed devices)." >&2
    exit 1
  fi
  verify_tree
  PUSH_FORCE=0
fi

git tag -f "$TAG" HEAD >/dev/null
echo "Fork master -> $(git log -1 --format='%h %s')"
echo "Tag $TAG     -> $(git rev-parse --short "$TAG^{commit}")"

if [[ -n "${DRY_RUN:-}" ]]; then echo "DRY_RUN: not pushing"; exit 0; fi
if [[ "$PUSH_FORCE" == 1 ]]; then
  git push -q --force origin master
else
  git push -q origin master
fi
# The fork may hold upstream's copy of this tag from when it was created
git push -q --force origin "refs/tags/$TAG"
echo "Pushed."

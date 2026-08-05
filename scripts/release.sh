#!/usr/bin/env bash
# Cut a release: tag main as vX.Y.Z and push. GitHub Actions does the rest -
# it builds the multi-arch image, pushes ghcr.io/<owner>/cast-to-roon:X.Y.Z and
# moves :latest to it, then opens a GitHub release.
#
#   ./scripts/release.sh patch     # 0.1.3 -> 0.1.4
#   ./scripts/release.sh minor     # 0.1.3 -> 0.2.0
#   ./scripts/release.sh major     # 0.1.3 -> 1.0.0
#   ./scripts/release.sh 1.2.3     # explicit version
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <patch|minor|major|X.Y.Z>"

cd "$(dirname "$0")/.."

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "main" ] || die "not on main (on '$branch')"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty - commit or stash first"

git fetch --tags --quiet origin
if [ -n "$(git log --oneline "origin/${branch}..${branch}")" ]; then
  die "local commits are not pushed yet - run 'git push' first"
fi

latest=$(git tag --list 'v*.*.*' --sort=-v:refname | head -n1)
latest=${latest:-v0.0.0}
IFS=. read -r major minor patch <<<"${latest#v}"

case "$1" in
  major) new="$((major + 1)).0.0" ;;
  minor) new="${major}.$((minor + 1)).0" ;;
  patch) new="${major}.${minor}.$((patch + 1))" ;;
  [0-9]*.[0-9]*.[0-9]*) new="$1" ;;
  *) die "unrecognized version bump: $1" ;;
esac

tag="v${new}"
git rev-parse -q --verify "refs/tags/${tag}" >/dev/null && die "tag ${tag} already exists"

echo "previous: ${latest}"
echo "new:      ${tag}"
read -r -p "tag and push? [y/N] " answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || die "aborted"

git tag -a "$tag" -m "Release ${tag}"
git push origin "$tag"

echo
echo "pushed ${tag} - watch the build:"
echo "  gh run watch \$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')"
echo
echo "when it is done, on Unraid:"
echo "  docker pull ghcr.io/lepis0/cast-to-roon:latest"

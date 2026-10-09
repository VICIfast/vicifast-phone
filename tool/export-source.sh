#!/usr/bin/env bash
# Publishes the app's source for one release into a clone of the public
# source repository, as GPLv3 requires for every build handed to agents.
#
#   tool/export-source.sh <git-ref> <public-repo-clone>
#
# Copies exactly the files tracked under apps/mobile at <git-ref> (nothing
# from the rest of the platform, no history), commits them as
# "Source for <version>" and tags v<version>. It never pushes: review the
# commit, then `git -C <clone> push --follow-tags`.
set -euo pipefail

ref="${1:?usage: tool/export-source.sh <git-ref> <public-repo-clone>}"
dest="${2:?usage: tool/export-source.sh <git-ref> <public-repo-clone>}"
root="$(git rev-parse --show-toplevel)"

[ -d "$dest/.git" ] || { echo "not a git clone: $dest" >&2; exit 1; }
git -C "$root" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "unknown ref: $ref" >&2; exit 1; }

version="$(git -C "$root" show "$ref:apps/mobile/pubspec.yaml" | sed -n 's/^version: *\([0-9.]*\).*/\1/p')"
[ -n "$version" ] || { echo "no version in pubspec.yaml at $ref" >&2; exit 1; }
if git -C "$dest" rev-parse --verify --quiet "refs/tags/v$version" >/dev/null; then
  echo "v$version is already published in $dest" >&2; exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# Internal CI notes stay private; everything else under apps/mobile ships.
git -C "$root" archive "$ref" apps/mobile | tar -x -C "$stage"
rm -f "$stage/apps/mobile/SIGNING.md"

# Refuse to publish anything that looks like a credential.
bad="$(cd "$stage/apps/mobile" && { find . -type f \( -name '*.jks' -o -name '*.keystore' -o -name '*.p8' -o -name '*.p12' \
  -o -name 'google-services.json' -o -name 'GoogleService-Info.plist' -o -name 'key.properties' \) -print;
  grep -rlIE 'BEGIN [A-Z ]*PRIVATE KEY' . || true; })"
if [ -n "$bad" ]; then
  echo "refusing to publish; these look like credentials:" >&2
  echo "$bad" >&2
  exit 1
fi

# Replace the clone's files with this release's, keeping its .git.
find "$dest" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$stage/apps/mobile/." "$dest/"

git -C "$dest" add -A
git -C "$dest" commit -q -m "Source for $version" -m "Built from $(git -C "$root" rev-parse --short "$ref")."
git -C "$dest" tag -a "v$version" -m "Source for $version"
echo "Committed and tagged v$version in $dest. Review it, then: git -C $dest push --follow-tags"

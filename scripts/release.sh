#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# Cut a release: guard hard, bump VERSION and the two mirrors that cannot read it at build time,
# commit, tag, push. The tag push is the only trigger; .github/workflows/release.yml does the
# build, the fence gates, packaging, checksums, and the GitHub Release.
#
# Usage: scripts/release.sh <version>     (semver MAJOR.MINOR.PATCH, ahead of the last tag)
#
# This pushes the release commit to main, so run it as a maintainer whose push to the protected
# branch is allowed. A release is a one-way door; every guard below refuses an ambiguous cut.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
NEW="${1:-}"
die() { echo "release: $1" >&2; exit 1; }

# --- guards -----------------------------------------------------------------
[ -n "$NEW" ] || die "usage: scripts/release.sh <version>"
printf '%s' "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || die "version must be semver MAJOR.MINOR.PATCH[-PRERELEASE], got '$NEW'"
[ "$(git branch --show-current)" = "main" ] \
  || die "cut releases from main, not '$(git branch --show-current)'"
git diff --quiet && git diff --cached --quiet || die "working tree is dirty; commit or stash first"
git fetch --tags --quiet
git rev-parse "v$NEW" >/dev/null 2>&1 && die "tag v$NEW already exists"
LAST="$(git tag --list 'v*' --sort=-v:refname | head -1)"
if [ -n "$LAST" ]; then
  newest="$(printf 'v%s\n%s\n' "$NEW" "$LAST" | sort -V | tail -1)"
  [ "$newest" = "v$NEW" ] || die "v$NEW is not ahead of the last tag $LAST"
fi

# CI must be green on this exact commit, so a release never ships a broken main.
head="$(git rev-parse HEAD)"
state="$(gh run list --branch main --limit 40 --json headSha,conclusion,status \
  --jq "[.[] | select(.headSha==\"$head\" and .status==\"completed\")]
        | if length==0 then \"none\" elif all(.conclusion==\"success\") then \"success\" else \"failed\" end" \
  2>/dev/null || echo "unknown")"
[ "$state" = "success" ] || die "CI on HEAD is '$state', not a green completed run; wait for it first"

# --- bump VERSION and the mirrors that cannot read it at build time ---------
# The .app's CFBundleShortVersionString reads VERSION at build; the CLI constant and package.json
# cannot, so rewrite them here.
printf '%s\n' "$NEW" > VERSION
CLI_VERSION_FILE="tools/simblectl/Sources/SimBLECTLKit/Version.swift"
sed -i.bak -E "s/(simblectlVersion = \")[^\"]+(\")/\1$NEW\2/" "$CLI_VERSION_FILE"
rm -f "$CLI_VERSION_FILE.bak"
python3 -c "import json,sys; d=json.load(open('package.json')); d['version']=sys.argv[1]; \
open('package.json','w').write(json.dumps(d, indent=2)+'\n')" "$NEW"

# --- commit, push main, tag, push tag ---------------------------------------
# Push main before tagging, so a rejected push (protected branch) leaves no dangling tag.
git add VERSION package.json "$CLI_VERSION_FILE"
git commit -m "chore(release): v$NEW"
git push origin main
git tag -a "v$NEW" -m "SimBLE v$NEW"
git push origin "v$NEW"
echo "release: pushed v$NEW; watch the release workflow build and publish it"

#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# curl -fsSL https://raw.githubusercontent.com/nirapod-labs/simble/main/scripts/install.sh | sh
#
# Build SimBLE from source on this Mac and install it: the menu bar helper to /Applications and the
# simblectl CLI to ~/.local/bin. Building locally keeps the binaries off the Gatekeeper quarantine
# path, and the ad-hoc signature is enough for a locally built tool.
#
# The source is cloned at a release tag (the latest release, or SIMBLE_REF=<tag>). The tag is
# validated to be a version tag before use, so the clone follows a published release, not a branch.
set -euo pipefail

REPO="nirapod-labs/simble"
REF="${SIMBLE_REF:-}" # a tag like v1.0.0; default is the latest release
APPS="/Applications"
BIN="${HOME}/.local/bin"
die() { echo "install: $1" >&2; exit 1; }

command -v git >/dev/null || die "git is required"
command -v xcrun >/dev/null || die "the Xcode command line tools are required: xcode-select --install"

if [ -z "$REF" ]; then
  # Resolve the release tag from VERSION on the default branch over raw.githubusercontent, the same
  # host this script was fetched from, so the install does not depend on the rate-limited GitHub API
  # and does not care whether the release is a prerelease.
  ver="$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$ver" ] || die "could not read the latest version; pass SIMBLE_REF=<tag> to build a specific tag"
  REF="v$ver"
fi

# Only follow a version tag (vX.Y.Z, optionally -prerelease), so the install stays pinned to a
# published release, not a moving branch.
printf '%s' "$REF" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || die "refusing to build '$REF': not a version tag (expected vX.Y.Z)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "install: cloning $REPO at $REF"
git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$WORK/src" >/dev/null 2>&1 \
  || die "could not clone $REPO at $REF"
cd "$WORK/src"

echo "install: building from source (ad-hoc signed, never quarantined)"
SIGN_ID="-" bash scripts/build-menubar-app.sh
( cd tools/simblectl && xcrun swift build -c release )

mkdir -p "$BIN"
rm -rf "$APPS/SimBLE.app"
cp -R dist/SimBLE.app "$APPS/SimBLE.app" \
  || die "could not write to $APPS (try: sudo, or set APPS=\$HOME/Applications)"
cp tools/simblectl/.build/release/simblectl "$BIN/simblectl"

echo "install: installed $APPS/SimBLE.app and $BIN/simblectl"
echo "install: open it with  open \"$APPS/SimBLE.app\"   (ensure $BIN is on PATH for the CLI)"

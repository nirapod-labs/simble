#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Clean.app/Contents" "$TMP/Dirty.app/Contents"
touch "$TMP/Dirty.app/Contents/simble-interpose.dylib"

bash "$REPO/scripts/fence-check.sh" --bundle "$TMP/Clean.app" >/dev/null
if bash "$REPO/scripts/fence-check.sh" --bundle "$TMP/Dirty.app" >/dev/null 2>&1; then
  echo "FENCE SELFTEST FAIL: dirty bundle passed" >&2
  exit 1
fi

echo "FENCE SELFTEST: ok"

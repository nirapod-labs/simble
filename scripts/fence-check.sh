#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Nirapod Labs
#
# Static fence assertions for the scaffold. Asserts the active invariant:
# debug injection names stay reviewed and consuming app projects do not link or
# bundle the interposer.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

DYLIB_NAME="simble-interpose"
VAR="DYLD_INSERT_LIBRARIES"
FAIL=0

fail() {
  echo "FENCE FAIL: $1" >&2
  FAIL=1
}

if [ "${1:-}" = "--bundle" ]; then
  BUNDLE="${2:-}"
  [ -d "$BUNDLE" ] || { echo "usage: fence-check.sh --bundle <path.app>" >&2; exit 2; }
  HITS="$(find "$BUNDLE" -name "*${DYLIB_NAME}*" 2>/dev/null)"
  [ -z "$HITS" ] || fail "interposer dylib inside bundle: $HITS"
  [ "$FAIL" -eq 0 ] && echo "FENCE (bundle): ok"
  exit "$FAIL"
fi

if [ "${1:-}" = "--helper" ]; then
  BUNDLE="${2:-}"
  [ -d "$BUNDLE" ] || { echo "usage: fence-check.sh --helper <path.app>" >&2; exit 2; }
  echo "FENCE (helper): placeholder ok"
  exit 0
fi

git ls-files '*.xcscheme' | while read -r scheme; do
  grep -q "$VAR" "$scheme" || continue
  launch_cfg="$(sed -n '/<LaunchAction/,/>/p' "$scheme" | grep -o 'buildConfiguration = "[^"]*"' | head -1)"
  case "$launch_cfg" in
    *'"Debug"'*) ;;
    *) echo "FENCE FAIL: $scheme carries $VAR outside Debug ($launch_cfg)" >&2
       touch .fence-violation ;;
  esac
done

git ls-files '*.xcconfig' | while read -r cfg; do
  grep -q "^[[:space:]]*$VAR" "$cfg" || continue
  case "$(basename "$cfg" | tr '[:upper:]' '[:lower:]')" in
    *debug*) ;;
    *) echo "FENCE FAIL: $cfg sets $VAR and is not a debug xcconfig" >&2
       touch .fence-violation ;;
  esac
done

HITS="$(git ls-files 'project.yml' '*/project.yml' '*.pbxproj' '*.xcconfig' '*Info.plist' \
        | xargs grep -l "$DYLIB_NAME" 2>/dev/null || true)"
[ -z "$HITS" ] || fail "interposer referenced by a project artifact: $HITS"

allowed() {
  case "$1" in
    scripts/fence-check.sh) return 0 ;;
    scripts/fence-selftest.sh) return 0 ;;
    apps/helper/Sources/SimBLEHelperKit/SimulatorArming.swift) return 0 ;;
    apps/helper/Sources/SimBLEHelperKit/InjectionEnv.swift) return 0 ;;
    apps/helper/Tests/SimBLEHelperKitTests/SimulatorArmingTests.swift) return 0 ;;
    .github/workflows/*) return 0 ;;
    SECURITY.md | README.md | docs/* | docs/**/*) return 0 ;;
    *.xcscheme | *.xcconfig) return 0 ;;
  esac
  return 1
}

git grep -l "$VAR" -- . | while read -r f; do
  allowed "$f" && continue
  echo "FENCE FAIL: $VAR referenced outside the allowlist: $f" >&2
  touch .fence-violation
done

if [ -e .fence-violation ]; then
  rm -f .fence-violation
  FAIL=1
fi

[ "$FAIL" -eq 0 ] && echo "FENCE (static): ok"
exit "$FAIL"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/Scripts/public-release.sh"

build_line="$(grep -nF 'SKIP_LOCAL_INSTALL=1 "$ROOT/Scripts/release.sh"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"
push_line="$(grep -nF 'git push -u origin "${BRANCH}"' "$SCRIPT" | head -1 | cut -d: -f1 || true)"

if [[ -z "$build_line" ]]; then
  echo "FAIL: make public does not build fresh local release artifacts" >&2
  exit 1
fi
if [[ -z "$push_line" || "$build_line" -ge "$push_line" ]]; then
  echo "FAIL: local release artifacts must be built before the public tag is pushed" >&2
  exit 1
fi

echo "PASS: make public builds local release artifacts before publishing"

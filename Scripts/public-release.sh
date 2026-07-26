#!/usr/bin/env bash
# Tag current commit and push so GitHub Actions builds the universal release.
# Usage:
#   make public                 # uses CFBundleShortVersionString from Info.plist
#   make public VERSION=1.2.0   # override marketing version
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v gh >/dev/null; then
  echo "error: gh CLI required (brew install gh && gh auth login)" >&2
  exit 1
fi
if ! command -v git >/dev/null; then
  echo "error: git required" >&2
  exit 1
fi

# Working tree must be clean
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean — commit or stash first" >&2
  git status --short
  exit 1
fi

PLIST="$ROOT/Resources/Info.plist"
VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "1.0.0")"
fi
# strip optional leading v
VERSION="${VERSION#v}"
TAG="v${VERSION}"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
  echo "warning: not on main/master (current: $BRANCH)" >&2
  read -r -p "Continue tagging from $BRANCH? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted"; exit 1 ;;
  esac
fi

# Ensure remote
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "error: no origin remote — create the GitHub repo and add origin first" >&2
  exit 1
fi

# Sync Info.plist version if override provided
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
if [[ "$CURRENT" != "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
  git add "$PLIST"
  git commit -m "chore: bump version to ${VERSION}"
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists locally" >&2
  echo "  delete with: git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
  exit 1
fi

echo "==> Pushing branch $BRANCH…"
git push -u origin "$BRANCH"

echo "==> Creating annotated tag $TAG…"
git tag -a "$TAG" -m "LocalClip ${VERSION}"

echo "==> Pushing tag $TAG (triggers GitHub Release workflow)…"
git push origin "$TAG"

echo ""
echo "=========================================="
echo "  Tag $TAG pushed."
echo "  CI will build universal ZIP/DMG and attach to the GitHub Release."
echo "  Watch: gh run watch"
echo "  Or:    https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/actions"
echo "=========================================="

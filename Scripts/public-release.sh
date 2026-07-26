#!/usr/bin/env bash
# Tag current commit and push so GitHub Actions builds the universal release.
# Usage:
#   make public                 # auto-bump patch: latest tag/plist → +0.0.1
#   make public VERSION=1.2.0   # explicit marketing version
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
  echo "error: working tree not clean - commit or stash first" >&2
  git status --short
  exit 1
fi

PLIST="$ROOT/Resources/Info.plist"

# --- version helpers ---
normalize_ver() {
  local v="${1:-0.0.0}"
  v="${v#v}"
  v="${v#V}"
  echo "$v"
}

# Compare a.b.c style: returns 0 if equal, 1 if $1>$2, 2 if $1<$2
ver_gt() {
  local a b
  a="$(normalize_ver "$1")"
  b="$(normalize_ver "$2")"
  local IFS=.
  # shellcheck disable=SC2206
  local aa=($a) bb=($b)
  local i n
  n=$(( ${#aa[@]} > ${#bb[@]} ? ${#aa[@]} : ${#bb[@]} ))
  for ((i = 0; i < n; i++)); do
    local x="${aa[i]:-0}"
    local y="${bb[i]:-0}"
    x="${x//[^0-9]/}"
    y="${y//[^0-9]/}"
    x="${x:-0}"
    y="${y:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 1
}

bump_patch() {
  local v
  v="$(normalize_ver "$1")"
  local major minor patch
  IFS=. read -r major minor patch <<<"${v}.0.0"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  major="${major//[^0-9]/}"
  minor="${minor//[^0-9]/}"
  patch="${patch//[^0-9]/}"
  major="${major:-0}"
  minor="${minor:-0}"
  patch="${patch:-0}"
  patch=$((10#$patch + 1))
  echo "${major}.${minor}.${patch}"
}

# Highest semver among local+remote tags matching v*
latest_tag_version() {
  # Fetch remote tags (quiet); ignore failure offline
  git fetch --tags --quiet origin 2>/dev/null || true
  local best="0.0.0"
  local t ver
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    ver="$(normalize_ver "$t")"
    if ver_gt "$ver" "$best"; then
      best="$ver"
    fi
  done < <(git tag -l 'v*' 2>/dev/null; git ls-remote --tags origin 'v*' 2>/dev/null | sed -E 's#.*refs/tags/(v[^^{}]+).*#\1#' | sort -u)
  echo "$best"
}

PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "0.0.0")"
PLIST_VERSION="$(normalize_ver "$PLIST_VERSION")"
TAG_VERSION="$(latest_tag_version)"

# Base = max(plist, latest tag)
BASE="$PLIST_VERSION"
if ver_gt "$TAG_VERSION" "$BASE"; then
  BASE="$TAG_VERSION"
fi

VERSION="${VERSION:-}"
if [[ -z "${VERSION}" ]]; then
  # Auto-increment patch when not specified
  VERSION="$(bump_patch "$BASE")"
  echo "==> Auto version: base ${BASE} (plist=${PLIST_VERSION}, latest_tag=${TAG_VERSION}) -> ${VERSION}"
else
  VERSION="$(normalize_ver "$VERSION")"
  echo "==> Explicit version: ${VERSION}"
fi

TAG="v${VERSION}"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${BRANCH}" != "main" && "${BRANCH}" != "master" ]]; then
  echo "warning: not on main/master (current: ${BRANCH})" >&2
  if [[ "${FORCE_PUBLIC:-0}" != "1" ]]; then
    echo "error: refuse to tag from ${BRANCH} (set FORCE_PUBLIC=1 to override)" >&2
    exit 1
  fi
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "error: no origin remote" >&2
  exit 1
fi

# Update Info.plist if needed and commit
CURRENT="$(normalize_ver "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")")"
if [[ "${CURRENT}" != "${VERSION}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$PLIST"
  BUILD="$(date +%s)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$PLIST" 2>/dev/null || true
  git add "$PLIST"
  git commit -m "chore: bump version to ${VERSION}"
fi

if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "error: tag ${TAG} already exists locally" >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null | grep -q .; then
  echo "error: tag ${TAG} already exists on origin" >&2
  exit 1
fi

echo "==> Pushing branch ${BRANCH}"
git push -u origin "${BRANCH}"

echo "==> Creating annotated tag ${TAG}"
git tag -a "${TAG}" -m "LocalClip ${VERSION}"

echo "==> Pushing tag ${TAG} (triggers GitHub Release workflow)"
git push origin "${TAG}"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
echo ""
echo "=========================================="
echo "  Tag ${TAG} pushed."
echo "  CI builds universal ZIP/DMG and attaches to the Release."
echo "  Watch:  gh run list --workflow=release.yml"
echo "  Actions: https://github.com/${REPO}/actions"
echo "=========================================="

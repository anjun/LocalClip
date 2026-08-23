#!/usr/bin/env bash

# Choose an installed SDK that the active Swift compiler can actually import.
# This also handles a partially updated Command Line Tools installation, where
# the compiler and the MacOSX.sdk symlink can temporarily be out of sync.
localclip_configure_swift_env() {
  local root="$1"
  local cache="$root/.build/localclip-module-cache"
  mkdir -p "$cache"
  export CLANG_MODULE_CACHE_PATH="$cache/clang"
  export SWIFTPM_MODULECACHE_OVERRIDE="$cache/swiftpm"

  if [[ -n "${SDKROOT:-}" ]] && localclip_sdk_works "$SDKROOT" "$cache"; then
    return 0
  fi

  local default_sdk=""
  default_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  if [[ -n "$default_sdk" ]] && localclip_sdk_works "$default_sdk" "$cache"; then
    export SDKROOT="$default_sdk"
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != "$default_sdk" ]] || continue
    if localclip_sdk_works "$candidate" "$cache"; then
      export SDKROOT="$candidate"
      echo "warning: active Swift cannot import ${default_sdk:-the default SDK}; using $candidate" >&2
      return 0
    fi
  done < <(
    find /Library/Developer/CommandLineTools/SDKs \
      -maxdepth 1 -type d -name 'MacOSX*.sdk' -print 2>/dev/null \
      | sort -Vr
  )

  echo "error: no installed macOS SDK is compatible with $(swift --version | head -1)" >&2
  return 1
}

localclip_sdk_works() {
  local sdk="$1"
  local cache="$2"
  local arch cache_key
  arch="$(uname -m)"
  cache_key="$(basename "$(readlink "$sdk" 2>/dev/null || printf '%s' "$sdk")")"
  printf 'import Foundation\n' \
    | swiftc \
      -sdk "$sdk" \
      -target "${arch}-apple-macosx14.0" \
      -module-cache-path "$cache/probe-${cache_key}" \
      -typecheck - >/dev/null 2>&1
}

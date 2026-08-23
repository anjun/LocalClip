#!/usr/bin/env bash

# Resolve one canonical local install path. Prefer the system Applications copy
# when it already exists because that is also the documented end-user location.
localclip_install_dir() {
  local chosen="${LOCALCLIP_INSTALL_DIR:-}"
  if [[ -z "$chosen" ]]; then
    if [[ -d "/Applications/LocalClip.app" ]]; then
      chosen="/Applications"
    elif [[ -d "${HOME}/Applications/LocalClip.app" ]]; then
      chosen="${HOME}/Applications"
    elif [[ -w "/Applications" ]]; then
      chosen="/Applications"
    else
      chosen="${HOME}/Applications"
    fi
  fi

  if [[ "$chosen" != /* ]]; then
    echo "error: LOCALCLIP_INSTALL_DIR must be an absolute path: $chosen" >&2
    return 1
  fi
  printf '%s\n' "$chosen"
}

localclip_install_app() {
  printf '%s/LocalClip.app\n' "$(localclip_install_dir)"
}

localclip_warn_duplicate_install() {
  if [[ -d "/Applications/LocalClip.app" && -d "${HOME}/Applications/LocalClip.app" ]]; then
    echo "warning: duplicate LocalClip apps detected:" >&2
    echo "  /Applications/LocalClip.app" >&2
    echo "  ${HOME}/Applications/LocalClip.app" >&2
    echo "  Using $(localclip_install_app); remove or archive the other copy to avoid TCC identity conflicts." >&2
  fi
}

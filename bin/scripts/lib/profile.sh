#!/usr/bin/env bash
# Profile parsing helpers.
#
# Source from any script:
#   source "$(dirname "$0")/lib/profile.sh"
#
# Usage:
#   parse_profile profiles/default.toml
#   # Sets: SANDBOX_IMAGE, SANDBOX_COMMAND, SANDBOX_NAME,
#   #       SANDBOX_PROVIDERS, SANDBOX_ENV, SANDBOX_KEEP

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

parse_profile() {
  local profile_file="$1"
  [[ -f "$profile_file" ]] || { echo "ERROR: $profile_file not found."; exit 1; }
  eval "$(python3 "$LIB_DIR/parse-profile.py" "$profile_file")"
}

# Build provider flags array from SANDBOX_PROVIDERS.
# Sets: PROVIDER_FLAGS array
build_provider_flags() {
  PROVIDER_FLAGS=()
  for name in $SANDBOX_PROVIDERS; do
    if "$CLI" provider get "$name" &>/dev/null; then
      PROVIDER_FLAGS+=(--provider "$name")
      echo "  $name: attached"
    else
      echo "  $name: not registered (skipping)"
    fi
  done
}

# Stage sandbox.env + GWS credentials to a directory for upload.
# The directory name must be "openshell" so upload lands at /sandbox/.config/openshell/.
stage_harness_dir() {
  local dir="$1"
  mkdir -p "$dir"

  if [[ -n "${SANDBOX_ENV:-}" ]]; then
    echo "$SANDBOX_ENV" > "$dir/sandbox.env"
  fi

  if command -v gws &>/dev/null && gws auth status &>/dev/null 2>&1; then
    gws auth export --unmasked > "$dir/credentials.json" 2>/dev/null
    cp ~/.config/gws/client_secret.json "$dir/client_secret.json" 2>/dev/null || true
    echo "  GWS: exported"
  else
    echo "  GWS: not configured (skipping)"
  fi
}

# Strip ANSI escape codes from stdin.
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

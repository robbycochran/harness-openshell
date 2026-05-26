#!/usr/bin/env bash
# Register credential providers with the OpenShell gateway.
#
# Run this after deploy.sh and after starting the port-forward.
# Credentials are read from environment variables on your machine and
# stored in the gateway's database — they are injected into sandbox pods
# automatically when you pass --provider flags to sandbox create.
#
# Usage:
#   export GITHUB_TOKEN="ghp_..."
#   export JIRA_URL="https://mysite.atlassian.net"
#   export JIRA_USERNAME="user@example.com"
#   export JIRA_API_TOKEN="ATATT..."
#   export ANTHROPIC_API_KEY="sk-ant-..."        # if using Anthropic directly
#   ./setup-providers.sh
#
# For Vertex AI: no env var needed here — ADC file is uploaded at sandbox creation time.
#
# To update credentials later, re-run this script or use:
#   openshell provider update <name> --credential KEY=NEW_VALUE

set -euo pipefail

GATEWAY_NAME="${GATEWAY_NAME:-ocp}"
export OPENSHELL_GATEWAY="$GATEWAY_NAME"

CLI="${OPENSHELL_CLI:-openshell}"
if ! command -v "$CLI" &>/dev/null; then
  REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  CLI="$REPO_ROOT/OpenShell/target/debug/openshell"
fi

if ! "$CLI" gateway select "$GATEWAY_NAME" &>/dev/null; then
  echo "ERROR: Gateway '$GATEWAY_NAME' not registered. Run deploy.sh first."
  exit 1
fi

created=0
skipped=0
failed=0

register_provider() {
  local name="$1" type="$2"
  shift 2
  local cred_args=("$@")

  if "$CLI" provider get "$name" &>/dev/null 2>&1; then
    echo "  ↻ $name — already exists, updating credentials"
    if "$CLI" provider update "$name" "${cred_args[@]}" 2>/dev/null; then
      ((created++))
    else
      echo "  ✗ $name — update failed"
      ((failed++))
    fi
  else
    if "$CLI" provider create --name "$name" --type "$type" "${cred_args[@]}" 2>/dev/null; then
      echo "  ✓ $name — registered"
      ((created++))
    else
      echo "  ✗ $name — creation failed"
      ((failed++))
    fi
  fi
}

echo "Registering providers with gateway '$GATEWAY_NAME'..."
echo ""

# ── GitHub ─────────────────────────────────────────────────────────────
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  register_provider github github \
    --credential "GITHUB_TOKEN=$GITHUB_TOKEN"
else
  echo "  – github — skipped (GITHUB_TOKEN not set)"
  ((skipped++))
fi

# ── Atlassian (Jira + Confluence) ─────────────────────────────────────
if [[ -n "${JIRA_URL:-}" && -n "${JIRA_USERNAME:-}" && -n "${JIRA_API_TOKEN:-}" ]]; then
  register_provider atlassian generic \
    --credential "JIRA_URL=$JIRA_URL" \
    --credential "JIRA_USERNAME=$JIRA_USERNAME" \
    --credential "JIRA_API_TOKEN=$JIRA_API_TOKEN"
else
  echo "  – atlassian — skipped (JIRA_URL, JIRA_USERNAME, or JIRA_API_TOKEN not set)"
  ((skipped++))
fi

# ── Anthropic (direct API) ────────────────────────────────────────────
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  register_provider anthropic anthropic \
    --credential "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
else
  echo "  – anthropic — skipped (ANTHROPIC_API_KEY not set)"
  ((skipped++))
fi

echo ""
echo "Done: $created registered, $skipped skipped, $failed failed."
echo ""
echo "Verify with:"
echo "  openshell provider list"
echo ""
echo "Providers are attached to sandboxes with --provider flags:"
echo "  openshell sandbox create --provider github --provider atlassian ..."

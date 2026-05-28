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
#   export ANTHROPIC_API_KEY="sk-ant-..."        # if using Anthropic directly
#   ./setup-providers.sh
#
# Note: Atlassian credentials (JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN)
# are NOT registered as providers. They are passed as literal env vars
# by ocp-sandbox.sh because mcp-atlassian uses Basic auth, which
# base64-encodes the credentials — hiding the placeholder tokens from
# the proxy's credential resolver.
#
# For Vertex AI: All ADC fields are extracted from the local ADC file
# and registered as the gcp-adc provider. The sandbox reconstructs
# adc.json from provider env vars. Requires jq.
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
      ((created++)) || true
    else
      echo "  ✗ $name — update failed"
      ((failed++)) || true
    fi
  else
    if "$CLI" provider create --name "$name" --type "$type" "${cred_args[@]}" 2>/dev/null; then
      echo "  ✓ $name — registered"
      ((created++)) || true
    else
      echo "  ✗ $name — creation failed"
      ((failed++)) || true
    fi
  fi
}

echo "Registering providers with gateway '$GATEWAY_NAME'..."
echo ""

# ── GitHub ─────────────────────────────────────────────────────────────
# Token is injected as a placeholder env var. The sandbox proxy resolves
# it transparently in Authorization headers (Bearer auth).
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  register_provider github github \
    --credential "GITHUB_TOKEN=$GITHUB_TOKEN"
else
  echo "  – github — skipped (GITHUB_TOKEN not set)"
  ((skipped++)) || true
fi

# ── Anthropic (direct API) ────────────────────────────────────────────
# Same Bearer auth pattern — proxy resolves the placeholder in headers.
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  register_provider anthropic anthropic \
    --credential "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
else
  echo "  – anthropic — skipped (ANTHROPIC_API_KEY not set)"
  ((skipped++)) || true
fi

# ── GCP ADC (Vertex AI) ──────────────────────────────────────────────
# Only the two secret fields (client_secret, refresh_token) are stored
# as provider credentials. These flow through HTTP during OAuth token
# exchange, where the proxy resolves placeholders via L7 body rewrite.
#
# Non-secret fields (client_id, account, type, etc.) are read locally
# from the ADC file by Google's auth library — placeholders wouldn't
# work there. ocp-sandbox.sh reads those from the ADC file at launch
# time and injects them as literal env vars.
ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [[ -f "$ADC_FILE" ]]; then
  if ! command -v jq &>/dev/null; then
    echo "  ✗ gcp-adc — jq required to extract ADC secrets"
    ((failed++)) || true
  else
    ADC_CLIENT_SECRET=$(jq -r '.client_secret // empty' "$ADC_FILE")
    ADC_REFRESH_TOKEN=$(jq -r '.refresh_token // empty' "$ADC_FILE")
    if [[ -n "$ADC_CLIENT_SECRET" && -n "$ADC_REFRESH_TOKEN" ]]; then
      register_provider gcp-adc generic \
        --credential "ADC_CLIENT_SECRET=$ADC_CLIENT_SECRET" \
        --credential "ADC_REFRESH_TOKEN=$ADC_REFRESH_TOKEN"
    else
      echo "  – gcp-adc — skipped (ADC file missing client_secret or refresh_token)"
      ((skipped++)) || true
    fi
  fi
else
  echo "  – gcp-adc — skipped (no ADC file at $ADC_FILE)"
  ((skipped++)) || true
fi

echo ""
echo "Done: $created registered, $skipped skipped, $failed failed."
echo ""
echo "Note: Atlassian credentials are passed directly by ocp-sandbox.sh"
echo "(Basic auth — placeholders can't be used). Set JIRA_URL,"
echo "JIRA_USERNAME, JIRA_API_TOKEN in your environment before running"
echo "ocp-sandbox.sh."
echo ""
echo "Note: mcp-atlassian also supports OAuth Bearer auth via"
echo "ATLASSIAN_OAUTH_ACCESS_TOKEN + ATLASSIAN_OAUTH_CLOUD_ID, which"
echo "would work with provider placeholders. However, OAuth access tokens"
echo "expire (~1 hour) and OpenShell doesn't yet support token refresh."
echo ""
echo "Verify providers with:"
echo "  openshell provider list"
echo ""
echo "Providers are attached to sandboxes automatically by ocp-sandbox.sh."

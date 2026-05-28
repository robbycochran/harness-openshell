#!/usr/bin/env bash
# Create and connect to an OpenShell sandbox on the OCP cluster.
#
# Credentials come from the provider system (GitHub, Anthropic, GCP ADC)
# and literal environment variables (Atlassian). GWS credentials are
# uploaded as files. ADC secrets are decomposed into provider credentials
# and reconstructed in-sandbox with placeholder tokens.
#
# Usage:
#   ./ocp-sandbox.sh                       # interactive Claude session
#   ./ocp-sandbox.sh --shell               # interactive shell (type 'claude' to start)
#   ./ocp-sandbox.sh --name my-sandbox     # named sandbox
#   ./ocp-sandbox.sh --no-keep             # delete sandbox after exit
#   ./ocp-sandbox.sh --rejoin my-sandbox   # reconnect to existing sandbox
#   ./ocp-sandbox.sh --editor vscode       # open in VS Code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GATEWAY_NAME="${GATEWAY_NAME:-ocp}"
export OPENSHELL_GATEWAY="$GATEWAY_NAME"

CLI="${OPENSHELL_CLI:-openshell}"
if ! command -v "$CLI" &>/dev/null; then
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  CLI="$REPO_ROOT/OpenShell/target/debug/openshell"
fi
[[ -x "$CLI" ]] || { echo "ERROR: openshell CLI not found. Install it or set OPENSHELL_CLI."; exit 1; }

# ── Parse args ─────────────────────────────────────────────────────────
SHELL_MODE=false
NO_KEEP=false
REJOIN=""
NAME_ARGS=()
EXTRA_PROVIDERS=()
EDITOR_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --shell)     SHELL_MODE=true; shift ;;
    --no-keep)   NO_KEEP=true; shift ;;
    --rejoin)    REJOIN="$2"; shift 2 ;;
    --name)      NAME_ARGS=(--name "$2"); shift 2 ;;
    --provider)  EXTRA_PROVIDERS+=(--provider "$2"); shift 2 ;;
    --editor)    EDITOR_ARGS=(--editor "$2"); shift 2 ;;
    *)           shift ;;
  esac
done

# ── Ensure port-forward ───────────────────────────────────────────────
if ! lsof -i :18443 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Starting port-forward..."
  nohup kubectl port-forward svc/openshell -n openshell 18443:8080 >/tmp/openshell-pf.log 2>&1 &
  sleep 2
fi

# ── Rejoin mode ────────────────────────────────────────────────────────
if [[ -n "$REJOIN" ]]; then
  echo "Reconnecting to $REJOIN..."
  exec "$CLI" sandbox connect "$REJOIN" "${EDITOR_ARGS[@]}"
fi

# ── Build provider flags from registered providers ─────────────────────
PROVIDER_FLAGS=()
if "$CLI" provider get github &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider github)
fi
if "$CLI" provider get anthropic &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider anthropic)
fi

if "$CLI" provider get gcp-adc &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider gcp-adc)
fi

PROVIDER_FLAGS+=("${EXTRA_PROVIDERS[@]}")

# ── Stage upload directory ─────────────────────────────────────────────
# The CLI accepts a single --upload flag, so we stage everything into
# one temp directory and upload it to /sandbox/.harness.
UPLOAD_DIR=$(mktemp -d)
trap 'rm -rf "$UPLOAD_DIR"' EXIT

VERTEX_PROJECT="${VERTEX_PROJECT:-}"
VERTEX_REGION="${VERTEX_REGION:-}"

# ── Read non-secret ADC fields from local file ───────────────────────
# These are injected as literal env vars because Google's auth library
# reads them locally from the JSON file — placeholders won't work.
# Only client_secret and refresh_token are provider-managed (sent via HTTP).
ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
ADC_CLIENT_ID=""
ADC_ACCOUNT=""
ADC_QUOTA_PROJECT_ID=""
ADC_TYPE=""
ADC_UNIVERSE_DOMAIN=""
if [[ -f "$ADC_FILE" ]] && command -v jq &>/dev/null; then
  ADC_CLIENT_ID=$(jq -r '.client_id // empty' "$ADC_FILE")
  ADC_ACCOUNT=$(jq -r '.account // empty' "$ADC_FILE")
  ADC_QUOTA_PROJECT_ID=$(jq -r '.quota_project_id // empty' "$ADC_FILE")
  ADC_TYPE=$(jq -r '.type // empty' "$ADC_FILE")
  ADC_UNIVERSE_DOMAIN=$(jq -r '.universe_domain // empty' "$ADC_FILE")
fi

# GWS credentials directory
GWS_CONFIG_DIR="${GWS_CONFIG_DIR:-$HOME/.config/gws}"
HAS_GWS=false
if [[ -d "$GWS_CONFIG_DIR" && -f "$GWS_CONFIG_DIR/client_secret.json" ]]; then
  mkdir -p "$UPLOAD_DIR/gws-config"
  cp "$GWS_CONFIG_DIR"/* "$UPLOAD_DIR/gws-config/" 2>/dev/null || true
  HAS_GWS=true
fi

# sandbox-CLAUDE.md
if [[ -f "$SCRIPT_DIR/sandbox-CLAUDE.md" ]]; then
  cp "$SCRIPT_DIR/sandbox-CLAUDE.md" "$UPLOAD_DIR/CLAUDE.md"
fi

UPLOAD_ARGS=(--upload "$UPLOAD_DIR:/sandbox/.harness")

# ── Sandbox env vars ──────────────────────────────────────────────────
# Atlassian credentials are passed as literal env vars (not via provider)
# because mcp-atlassian uses Basic auth — base64-encoding hides the
# placeholder tokens from the proxy's credential resolver.
JIRA_URL="${JIRA_URL:-}"
JIRA_USERNAME="${JIRA_USERNAME:-}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"

ENV_BLOCK=""
ENV_BLOCK+="export GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json
"
ENV_BLOCK+="export CLAUDE_CODE_USE_VERTEX=1
"
ENV_BLOCK+="export CLOUD_ML_REGION=global
"
[[ -n "$VERTEX_PROJECT" ]] && ENV_BLOCK+="export ANTHROPIC_VERTEX_PROJECT_ID=$VERTEX_PROJECT
export GOOGLE_CLOUD_PROJECT=$VERTEX_PROJECT
"
[[ -n "$VERTEX_REGION" ]] && ENV_BLOCK+="export GOOGLE_CLOUD_LOCATION=$VERTEX_REGION
"

# Non-secret ADC fields (literal values, read locally by Google auth library)
[[ -n "$ADC_CLIENT_ID" ]] && ENV_BLOCK+="export ADC_CLIENT_ID=$ADC_CLIENT_ID
"
[[ -n "$ADC_ACCOUNT" ]] && ENV_BLOCK+="export ADC_ACCOUNT=$ADC_ACCOUNT
"
[[ -n "$ADC_QUOTA_PROJECT_ID" ]] && ENV_BLOCK+="export ADC_QUOTA_PROJECT_ID=$ADC_QUOTA_PROJECT_ID
"
[[ -n "$ADC_TYPE" ]] && ENV_BLOCK+="export ADC_TYPE=$ADC_TYPE
"
[[ -n "$ADC_UNIVERSE_DOMAIN" ]] && ENV_BLOCK+="export ADC_UNIVERSE_DOMAIN=$ADC_UNIVERSE_DOMAIN
"

# Atlassian env vars (literal values, not provider placeholders).
# Base64-encode to avoid shell injection through multi-layer expansion.
[[ -n "$JIRA_URL" ]] && ENV_BLOCK+="export JIRA_URL=\$(echo '$(echo -n "$JIRA_URL" | base64)' | base64 -d)
"
[[ -n "$JIRA_USERNAME" ]] && ENV_BLOCK+="export JIRA_USERNAME=\$(echo '$(echo -n "$JIRA_USERNAME" | base64)' | base64 -d)
"
[[ -n "$JIRA_API_TOKEN" ]] && ENV_BLOCK+="export JIRA_API_TOKEN=\$(echo '$(echo -n "$JIRA_API_TOKEN" | base64)' | base64 -d)
"

ENV_BLOCK+='export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config
'
ENV_BLOCK+='export CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=1
'
ENV_BLOCK+='export PATH="/sandbox/.local/bin:$PATH"
'

# ── Create sandbox ─────────────────────────────────────────────────────
echo "Creating sandbox..."

KEEP_ARGS=()
$NO_KEEP && KEEP_ARGS=(--no-keep)

GWS_SETUP=""
if $HAS_GWS; then
  GWS_SETUP='
mkdir -p /tmp/gws-config
cp /sandbox/.harness/gws-config/* /tmp/gws-config/ 2>/dev/null || true
'
fi

"$CLI" sandbox create \
  --policy "$SCRIPT_DIR/vertex-policy.yaml" \
  "${UPLOAD_ARGS[@]}" \
  "${PROVIDER_FLAGS[@]}" \
  "${KEEP_ARGS[@]}" \
  "${NAME_ARGS[@]}" \
  "${EDITOR_ARGS[@]}" \
  -- bash -c '
# ── Sandbox setup (runs once) ──────────────────────────────────────
rm -rf /sandbox/.claude/plugins /sandbox/.claude.json 2>/dev/null

# Move staged files from upload directory
[[ -f /sandbox/.harness/CLAUDE.md ]] && cp /sandbox/.harness/CLAUDE.md /sandbox/CLAUDE.md

# Environment file for reconnects
cat > /sandbox/.openshell-env <<ENVEOF
'"$ENV_BLOCK"'ENVEOF

grep -q openshell-env /sandbox/.bashrc 2>/dev/null || {
  echo ". ~/.openshell-env 2>/dev/null" >> /sandbox/.bashrc
}

. /sandbox/.openshell-env
'"$GWS_SETUP"'

# ADC: reconstruct from provider env vars (all fields injected by gcp-adc provider)
if [[ -n "${ADC_CLIENT_SECRET:-}" ]]; then
  cat > /tmp/adc.json <<ADCEOF
{
  "account": "${ADC_ACCOUNT:-}",
  "client_id": "${ADC_CLIENT_ID:-}",
  "client_secret": "${ADC_CLIENT_SECRET}",
  "quota_project_id": "${ADC_QUOTA_PROJECT_ID:-}",
  "refresh_token": "${ADC_REFRESH_TOKEN:-}",
  "type": "${ADC_TYPE:-authorized_user}",
  "universe_domain": "${ADC_UNIVERSE_DOMAIN:-googleapis.com}"
}
ADCEOF
fi

# Claude MCP config — use python3 to safely construct JSON (avoids injection)
if [[ -n "${JIRA_URL:-}" ]]; then
  python3 <<'"'"'PYEOF'"'"'
import json, os
config = {
    "autoUpdates": False,
    "hasCompletedOnboarding": True,
    "mcpServers": {
        "atlassian": {
            "type": "stdio",
            "command": "/sandbox/.venv/bin/mcp-atlassian",
            "args": [],
            "env": {
                "JIRA_URL": os.environ.get("JIRA_URL", ""),
                "JIRA_USERNAME": os.environ.get("JIRA_USERNAME", ""),
                "JIRA_API_TOKEN": os.environ.get("JIRA_API_TOKEN", ""),
                "CONFLUENCE_URL": os.environ.get("JIRA_URL", "") + "/wiki",
                "CONFLUENCE_USERNAME": os.environ.get("JIRA_USERNAME", ""),
                "CONFLUENCE_API_TOKEN": os.environ.get("JIRA_API_TOKEN", ""),
            }
        }
    }
}
with open("/sandbox/.claude.json", "w") as f:
    json.dump(config, f, indent=2)
PYEOF
else
  cat > /sandbox/.claude.json <<CJEOF
{
  "autoUpdates": false,
  "hasCompletedOnboarding": true
}
CJEOF
fi

mkdir -p /sandbox/.claude
cat > /sandbox/.claude/settings.json <<CSEOF
{"permissions":{"allow":["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","mcp__atlassian__*"],"deny":[]}}
CSEOF

# Install tools
pip install -q mcp-atlassian==0.21.1 </dev/null 2>&1 || echo "WARNING: mcp-atlassian install failed"
mkdir -p /sandbox/.local/bin
curl -fsSL -L https://github.com/googleworkspace/cli/releases/download/v0.22.5/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz </dev/null 2>/dev/null \
  | tar xz -C /sandbox/.local/bin 2>/dev/null || true

echo "Setup complete."

# Drop into interactive shell or claude
exec bash -l
'

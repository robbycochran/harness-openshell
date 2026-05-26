#!/usr/bin/env bash
# Create and connect to an OpenShell sandbox on the OCP cluster.
#
# Credentials come from the provider system (see setup-providers.sh).
# File-based credentials (ADC, GWS) are uploaded at sandbox creation time.
#
# Usage:
#   ./ocp-sandbox.sh                       # interactive Claude session
#   ./ocp-sandbox.sh --shell               # interactive shell (type 'claude' to start)
#   ./ocp-sandbox.sh --name my-sandbox     # named sandbox
#   ./ocp-sandbox.sh --no-keep             # delete sandbox after exit
#   ./ocp-sandbox.sh --rejoin my-sandbox   # reconnect to existing sandbox

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
while [[ $# -gt 0 ]]; do
  case $1 in
    --shell)     SHELL_MODE=true; shift ;;
    --no-keep)   NO_KEEP=true; shift ;;
    --rejoin)    REJOIN="$2"; shift 2 ;;
    --name)      NAME_ARGS=(--name "$2"); shift 2 ;;
    --provider)  EXTRA_PROVIDERS+=(--provider "$2"); shift 2 ;;
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
  exec "$CLI" sandbox connect "$REJOIN"
fi

# ── Build provider flags from registered providers ─────────────────────
PROVIDER_FLAGS=()
if "$CLI" provider get github &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider github)
fi
if "$CLI" provider get atlassian &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider atlassian)
fi
if "$CLI" provider get anthropic &>/dev/null 2>&1; then
  PROVIDER_FLAGS+=(--provider anthropic)
fi
PROVIDER_FLAGS+=("${EXTRA_PROVIDERS[@]}")

# ── Build upload flags ─────────────────────────────────────────────────
UPLOAD_ARGS=()

# Vertex AI ADC
ADC_FILE="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/.config/gcloud/application_default_credentials.json}"
if [[ -f "$ADC_FILE" ]]; then
  UPLOAD_ARGS+=(--upload "$ADC_FILE:/tmp/adc.json")
fi

VERTEX_PROJECT="${VERTEX_PROJECT:-}"
VERTEX_REGION="${VERTEX_REGION:-}"

# GWS credentials directory
GWS_CONFIG_DIR="${GWS_CONFIG_DIR:-$HOME/.config/gws}"
GWS_UPLOAD=false
if [[ -d "$GWS_CONFIG_DIR" && -f "$GWS_CONFIG_DIR/client_secret.json" ]]; then
  GWS_UPLOAD=true
fi

# ── Sandbox env vars (non-provider, Vertex AI config) ──────────────────
ENV_BLOCK=""
if [[ -f "$ADC_FILE" ]]; then
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
fi
ENV_BLOCK+='export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config
'
ENV_BLOCK+='export PATH="/sandbox/.local/bin:$PATH"
'

# ── Build Jira env for MCP config ──────────────────────────────────────
# The provider injects JIRA_URL, JIRA_USERNAME, JIRA_API_TOKEN as env vars.
# We reference them in the claude.json MCP config at startup.

# ── Create sandbox ─────────────────────────────────────────────────────
echo "Creating sandbox..."

KEEP_ARGS=()
$NO_KEEP && KEEP_ARGS=(--no-keep)

GWS_SETUP=""
if $GWS_UPLOAD; then
  GWS_SETUP='
mkdir -p /tmp/gws-config
cp /sandbox/gws-upload/* /tmp/gws-config/ 2>/dev/null || true
'
  UPLOAD_ARGS+=(--upload "$GWS_CONFIG_DIR:/sandbox/gws-upload")
fi

"$CLI" sandbox create \
  --policy "$SCRIPT_DIR/vertex-policy.yaml" \
  "${UPLOAD_ARGS[@]}" \
  "${PROVIDER_FLAGS[@]}" \
  "${KEEP_ARGS[@]}" \
  "${NAME_ARGS[@]}" \
  -- bash -c '
# ── Sandbox setup (runs once) ──────────────────────────────────────
rm -rf /sandbox/.claude/plugins /sandbox/.claude.json 2>/dev/null

# Environment file for reconnects
cat > /sandbox/.openshell-env <<ENVEOF
'"$ENV_BLOCK"'ENVEOF

grep -q openshell-env /sandbox/.bashrc 2>/dev/null || {
  echo ". ~/.openshell-env 2>/dev/null" >> /sandbox/.bashrc
  echo "alias claude=\"claude --dangerously-skip-permissions\"" >> /sandbox/.bashrc
}

. /sandbox/.openshell-env
'"$GWS_SETUP"'

# Claude MCP config — uses env vars injected by the atlassian provider
cat > /sandbox/.claude.json <<CJEOF
{
  "autoUpdates": false,
  "hasCompletedOnboarding": true,
  "mcpServers": {
    "atlassian": {
      "type": "stdio",
      "command": "/sandbox/.venv/bin/mcp-atlassian",
      "args": [],
      "env": {
        "JIRA_URL": "${JIRA_URL:-}",
        "JIRA_USERNAME": "${JIRA_USERNAME:-}",
        "JIRA_API_TOKEN": "${JIRA_API_TOKEN:-}",
        "CONFLUENCE_URL": "${JIRA_URL:-}/wiki",
        "CONFLUENCE_USERNAME": "${JIRA_USERNAME:-}",
        "CONFLUENCE_API_TOKEN": "${JIRA_API_TOKEN:-}"
      }
    }
  }
}
CJEOF

mkdir -p /sandbox/.claude
cat > /sandbox/.claude/settings.json <<CSEOF
{"permissions":{"allow":["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","mcp__atlassian__*"],"deny":[]}}
CSEOF

# Install tools
pip install -q mcp-atlassian </dev/null >/dev/null 2>&1 || true
mkdir -p /sandbox/.local/bin
curl -fsSL -L https://github.com/googleworkspace/cli/releases/download/v0.22.5/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz </dev/null 2>/dev/null \
  | tar xz -C /sandbox/.local/bin 2>/dev/null || true

# Auth gh CLI using the token injected by the github provider
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "$GITHUB_TOKEN" | gh auth login --with-token </dev/null >/dev/null 2>&1 || true
fi

echo "Setup complete."
' 2>&1

# ── Get sandbox name ───────────────────────────────────────────────────
if [[ ${#NAME_ARGS[@]} -gt 0 ]]; then
  SANDBOX_NAME="${NAME_ARGS[1]}"
else
  SANDBOX_NAME=$("$CLI" sandbox list --names 2>&1 | tail -1)
fi

echo "Connecting to $SANDBOX_NAME..."
"$CLI" sandbox connect "$SANDBOX_NAME"

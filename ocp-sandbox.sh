#!/usr/bin/env bash
# Create and connect to an OpenShell sandbox on the OCP cluster.
#
# Usage:
#   ./ocp-sandbox.sh                       # interactive Claude session
#   ./ocp-sandbox.sh --shell               # interactive shell (type 'claude' to start)
#   ./ocp-sandbox.sh --name my-sandbox     # named sandbox
#   ./ocp-sandbox.sh --keep                # keep sandbox alive after exit
#   ./ocp-sandbox.sh --rejoin my-sandbox   # reconnect to existing sandbox

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/kubeconfig}"
export OPENSHELL_GATEWAY=ocp

CLI="$REPO_ROOT/target/debug/openshell"
[[ -x "$CLI" ]] || { echo "CLI not built. Run: cargo build -p openshell-cli"; exit 1; }

# ── Parse args ──────────────────────────────────────────────────────────
SHELL_MODE=false
KEEP_FLAG="--no-keep"
REJOIN=""
NAME_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --shell)  SHELL_MODE=true; shift ;;
    --keep)   KEEP_FLAG=""; shift ;;
    --rejoin) REJOIN="$2"; shift 2 ;;
    --name)   NAME_ARGS=(--name "$2"); shift 2 ;;
    *)        shift ;;
  esac
done

# ── Ensure port-forward ────────────────────────────────────────────────
if ! lsof -i :18443 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Starting port-forward..."
  nohup kubectl port-forward svc/openshell -n openshell 18443:8080 >/tmp/openshell-pf.log 2>&1 &
  sleep 2
fi

# ── Ensure gateway config ──────────────────────────────────────────────
if [[ ! -f "$HOME/.config/openshell/gateways/ocp/metadata.json" ]]; then
  TLSDIR="$HOME/.openshell-ocp-tls"
  mkdir -p "$HOME/.config/openshell/gateways/ocp/mtls"
  cp "$TLSDIR/ca.crt" "$HOME/.config/openshell/gateways/ocp/mtls/"
  cp "$TLSDIR/client.crt" "$HOME/.config/openshell/gateways/ocp/mtls/tls.crt"
  cp "$TLSDIR/client.key" "$HOME/.config/openshell/gateways/ocp/mtls/tls.key"
  cat > "$HOME/.config/openshell/gateways/ocp/metadata.json" <<'EOF'
{"name":"ocp","gateway_endpoint":"https://127.0.0.1:18443","is_remote":false,"gateway_port":18443,"auth_mode":"mtls"}
EOF
fi

# ── Rejoin mode ─────────────────────────────────────────────────────────
if [[ -n "$REJOIN" ]]; then
  echo "Reconnecting to $REJOIN — type 'claude' to start."
  exec "$CLI" sandbox connect "$REJOIN"
fi

# ── Fetch credentials ───────────────────────────────────────────────────
echo "Fetching credentials..."
GH_TOKEN=$(kubectl get secret github-token -n openshell -o jsonpath='{.data.GITHUB_TOKEN}' | base64 -d)
JIRA_URL=$(kubectl get secret atlassian-creds -n openshell -o jsonpath='{.data.JIRA_URL}' | base64 -d)
JIRA_USER=$(kubectl get secret atlassian-creds -n openshell -o jsonpath='{.data.JIRA_USERNAME}' | base64 -d)
JIRA_TOKEN=$(kubectl get secret atlassian-creds -n openshell -o jsonpath='{.data.JIRA_API_TOKEN}' | base64 -d)
GWS_CS_B64=$(kubectl get secret gws-credentials -n openshell -o jsonpath='{.data.client_secret\.json}')
GWS_CR_B64=$(kubectl get secret gws-credentials -n openshell -o jsonpath='{.data.credentials\.enc}')
GWS_EK_B64=$(kubectl get secret gws-credentials -n openshell -o jsonpath='{.data.encryption_key}')
GWS_TC_B64=$(kubectl get secret gws-credentials -n openshell -o jsonpath='{.data.token_cache\.json}')

[[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]] || {
  echo "No ADC. Run: gcloud auth application-default login"; exit 1
}

VERTEX_PROJECT="itpc-gcp-hcm-pe-eng-claude"
VERTEX_REGION="us-east5"

# ── Create sandbox ──────────────────────────────────────────────────────
# Phase 1: create sandbox + upload ADC + run setup (setup consumes stdin, that's ok)
# Phase 2: connect with clean stdin for Claude
#
# The sandbox is always created with --keep so we can connect in phase 2.
# If the user didn't pass --keep, we note it and delete after disconnect.
USER_WANTS_KEEP=false
[[ "$KEEP_FLAG" == "" ]] && USER_WANTS_KEEP=true

echo "Creating sandbox..."
"$CLI" sandbox create \
  --policy "$SCRIPT_DIR/vertex-policy.yaml" \
  --upload "$HOME/.config/gcloud/application_default_credentials.json:/tmp/adc.json" \
  --no-bootstrap \
  --keep \
  "${NAME_ARGS[@]}" \
  -- bash -c '
# ── Setup (runs once, stdin is consumed, thats fine) ──
rm -rf /sandbox/.claude/plugins /sandbox/.claude.json 2>/dev/null

# Env file for reconnects
cat > /sandbox/.openshell-env <<ENVBLOCK
export GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=global
export ANTHROPIC_VERTEX_PROJECT_ID='"$VERTEX_PROJECT"'
export GOOGLE_CLOUD_LOCATION='"$VERTEX_REGION"'
export GOOGLE_CLOUD_PROJECT='"$VERTEX_PROJECT"'
export GITHUB_TOKEN='"'$GH_TOKEN'"'
export JIRA_URL='"'$JIRA_URL'"'
export JIRA_USERNAME='"'$JIRA_USER'"'
export JIRA_API_TOKEN='"'$JIRA_TOKEN'"'
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config
export PATH="/sandbox/.local/bin:\$PATH"
ENVBLOCK

grep -q openshell-env /sandbox/.bashrc 2>/dev/null || {
  echo ". ~/.openshell-env 2>/dev/null" >> /sandbox/.bashrc
  echo "alias claude=\"claude --dangerously-skip-permissions\"" >> /sandbox/.bashrc
}

. /sandbox/.openshell-env

# GWS config
mkdir -p /tmp/gws-config
echo "'"$GWS_CS_B64"'" | base64 -d > /tmp/gws-config/client_secret.json
echo "'"$GWS_CR_B64"'" | base64 -d > /tmp/gws-config/credentials.enc
echo "'"$GWS_EK_B64"'" | base64 -d > /tmp/gws-config/.encryption_key
echo "'"$GWS_TC_B64"'" | base64 -d > /tmp/gws-config/token_cache.json

# Claude config
cat > /sandbox/.claude.json <<CJEOF
{"autoUpdates":false,"hasCompletedOnboarding":true,"mcpServers":{"atlassian":{"type":"stdio","command":"/sandbox/.venv/bin/mcp-atlassian","args":[],"env":{"JIRA_URL":"'"$JIRA_URL"'","JIRA_USERNAME":"'"$JIRA_USER"'","JIRA_API_TOKEN":"'"$JIRA_TOKEN"'","CONFLUENCE_URL":"'"$JIRA_URL"'/wiki","CONFLUENCE_USERNAME":"'"$JIRA_USER"'","CONFLUENCE_API_TOKEN":"'"$JIRA_TOKEN"'"}}}}
CJEOF

mkdir -p /sandbox/.claude
cat > /sandbox/.claude/settings.json <<CSEOF
{"permissions":{"allow":["Bash(*)","Read(*)","Write(*)","Edit(*)","Glob(*)","Grep(*)","WebFetch(*)","WebSearch(*)","mcp__atlassian__*"],"deny":[]}}
CSEOF

# Install tools
pip install -q mcp-atlassian </dev/null >/dev/null 2>&1 || true
mkdir -p /sandbox/.local/bin
curl -fsSL -L https://github.com/googleworkspace/cli/releases/download/v0.22.5/google-workspace-cli-x86_64-unknown-linux-gnu.tar.gz </dev/null 2>/dev/null | tar xz -C /sandbox/.local/bin 2>/dev/null || true

# Auth gh
echo "$GITHUB_TOKEN" | gh auth login --with-token </dev/null >/dev/null 2>&1 || true

echo "Setup complete."
' 2>&1

# Get sandbox name
if [[ ${#NAME_ARGS[@]} -gt 0 ]]; then
  SANDBOX_NAME="${NAME_ARGS[1]}"
else
  SANDBOX_NAME=$("$CLI" sandbox list 2>&1 | grep Ready | tail -1 | awk '{print $1}')
fi

echo "Connecting to $SANDBOX_NAME..."

# Phase 2: connect with clean stdin — Claude gets pristine I/O
if $SHELL_MODE; then
  "$CLI" sandbox connect "$SANDBOX_NAME"
else
  "$CLI" sandbox connect "$SANDBOX_NAME"
fi

# Cleanup if user didn't want --keep
if ! $USER_WANTS_KEEP; then
  echo "Cleaning up sandbox $SANDBOX_NAME..."
  "$CLI" sandbox delete "$SANDBOX_NAME" 2>/dev/null || true
fi

#!/usr/bin/env bash
# Launch an OpenShell sandbox on the OCP cluster.
#
# Prerequisites (one-time):
#   ./deploy.sh
#   ./setup-providers.sh
#
# Usage:
#   ./sandbox.sh                        # interactive Claude session
#   ./sandbox.sh --name my-sandbox      # named sandbox
#   ./sandbox.sh --rejoin my-sandbox    # reconnect to existing sandbox
#   ./sandbox.sh --no-keep              # delete sandbox after exit
#   ./sandbox.sh --editor vscode        # open in VS Code
#
# GWS config files are uploaded as a workaround until OpenShell adds
# file-based credential projection (#1268, #1423). If the upload fails
# (supervisor race condition), just re-run this script.
set -euo pipefail

export OPENSHELL_GATEWAY="${GATEWAY_NAME:-ocp}"

CLI="${OPENSHELL_CLI:-openshell}"
command -v "$CLI" &>/dev/null || { echo "ERROR: openshell CLI not found."; exit 1; }

# ── Parse args ─────────────────────────────────────────────────────────
EXTRA=()
REJOIN=""
NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --rejoin)  REJOIN="$2"; shift 2 ;;
    --name)    NAME="$2"; EXTRA+=("$1" "$2"); shift 2 ;;
    --editor)  EXTRA+=("$1" "$2"); shift 2 ;;
    --no-keep) EXTRA+=("$1"); shift ;;
    --provider) EXTRA+=("$1" "$2"); shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Rejoin mode ────────────────────────────────────────────────────────
if [[ -n "$REJOIN" ]]; then
  echo "Reconnecting to sandbox: $REJOIN"
  exec "$CLI" sandbox connect "$REJOIN"
fi

# ── Pre-flight checks ─────────────────────────────────────────────────
echo "=== Pre-flight checks ==="

echo -n "  Gateway ($OPENSHELL_GATEWAY): "
"$CLI" inference get &>/dev/null && echo "reachable" || { echo "UNREACHABLE — run ./deploy.sh"; exit 1; }

echo -n "  Inference route: "
model=$("$CLI" inference get 2>/dev/null | grep Model: | awk '{print $2}')
if [[ -n "$model" ]]; then
  echo "$model"
else
  echo "NOT SET — run ./setup-providers.sh"
  exit 1
fi

# Clean up any previous failed sandbox with the same name
if [[ -n "$NAME" ]] && "$CLI" sandbox list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qFx "$NAME"; then
  echo "  Deleting existing sandbox: $NAME"
  "$CLI" sandbox delete "$NAME" 2>/dev/null || true
fi

# ── Detect registered providers ────────────────────────────────────────
echo ""
echo "=== Providers ==="
PROVIDER_FLAGS=()
for name in github vertex-local atlassian; do
  if "$CLI" provider get "$name" &>/dev/null; then
    PROVIDER_FLAGS+=(--provider "$name")
    echo "  $name: attached"
  else
    echo "  $name: not registered (skipping)"
  fi
done

# ── Stage files for upload ─────────────────────────────────────────────
echo ""
echo "=== Upload staging ==="
STAGE=$(mktemp -d)
CREDS="$STAGE/creds"
mkdir -p "$CREDS"
HAS_UPLOADS=false

# Atlassian: write non-secret config as JSON (URL and username aren't secrets;
# only JIRA_API_TOKEN needs provider placeholder resolution).
# Using python3 to avoid JSON injection from special chars in values.
if [[ -n "${JIRA_URL:-}" ]]; then
  python3 -c "
import json, sys
with open(sys.argv[1], 'w') as f:
    json.dump({'jira_url': sys.argv[2], 'jira_username': sys.argv[3]}, f)
" "$CREDS/atlassian.json" "$JIRA_URL" "${JIRA_USERNAME:-}"
  echo "  Atlassian config: $JIRA_URL"
  HAS_UPLOADS=true
fi

# GWS: export decrypted credentials (encrypted files are machine-specific
# and cannot be decrypted on a different machine).
if command -v gws &>/dev/null && gws auth status &>/dev/null; then
  mkdir -p "$CREDS/gws-config"
  if gws auth export --unmasked > "$CREDS/gws-config/credentials.json" 2>/dev/null; then
    GWS_DIR="${GWS_CONFIG_DIR:-$HOME/.config/gws}"
    [[ -f "$GWS_DIR/client_secret.json" ]] && cp "$GWS_DIR/client_secret.json" "$CREDS/gws-config/"
    chmod 600 "$CREDS/gws-config"/*
    echo "  GWS credentials: exported"
    HAS_UPLOADS=true
  else
    echo "  GWS: export failed (sandbox will launch without GWS)"
    rm -rf "$CREDS/gws-config"
  fi
else
  echo "  GWS: not authenticated (skipping — run 'gws auth login' first)"
fi

UPLOAD_ARGS=()
$HAS_UPLOADS && UPLOAD_ARGS=(--upload "$CREDS:/sandbox/.harness")

# ── Create sandbox ─────────────────────────────────────────────────────
echo ""
echo "=== Creating sandbox ==="
# Note: staging dir in /tmp is not cleaned up because exec replaces the
# process (traps don't fire) and the upload happens during exec. OS cleans /tmp.
exec "$CLI" sandbox create \
  --tty \
  ${PROVIDER_FLAGS[@]+"${PROVIDER_FLAGS[@]}"} \
  ${UPLOAD_ARGS[@]+"${UPLOAD_ARGS[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -- bash -c '. /sandbox/startup.sh && exec claude --bare'

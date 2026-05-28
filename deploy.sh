#!/usr/bin/env bash
# Deploy OpenShell to an OpenShift cluster using the official Helm chart.
#
# Usage:
#   ./deploy.sh                           # full deploy
#   ./deploy.sh --kubeconfig ./kubeconfig  # explicit kubeconfig
#
# Environment variables (all optional, sensible defaults provided):
#   OPENSHELL_REPO          — path to NVIDIA/OpenShell checkout (default: ../OpenShell)
#   GATEWAY_IMAGE_REPO      — gateway image repo   (default: ghcr.io/nvidia/openshell/gateway)
#   GATEWAY_IMAGE_TAG       — gateway image tag     (default: chart appVersion)
#   SUPERVISOR_IMAGE_REPO   — supervisor image repo (default: ghcr.io/nvidia/openshell/supervisor)
#   SANDBOX_IMAGE           — sandbox base image    (default: ghcr.io/nvidia/openshell-community/sandboxes/base:latest)
#   PULL_SECRET             — imagePullSecrets name  (default: none)
#   GATEWAY_NAME            — CLI gateway name       (default: ocp)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case $1 in
    --kubeconfig) export KUBECONFIG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

OPENSHELL_REPO="${OPENSHELL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)/OpenShell}"
if [[ ! -d "$OPENSHELL_REPO/deploy/helm/openshell" ]]; then
  echo "ERROR: OpenShell repo not found at $OPENSHELL_REPO"
  echo "Set OPENSHELL_REPO or clone NVIDIA/OpenShell alongside this repo"
  exit 1
fi

GATEWAY_NAME="${GATEWAY_NAME:-ocp}"

echo "Using OpenShell repo: $OPENSHELL_REPO"
echo "Using KUBECONFIG: ${KUBECONFIG:-default}"
echo ""

# ── Step 1: Namespace ──────────────────────────────────────────────────
echo "=== Step 1: Creating namespace ==="
kubectl create ns openshell 2>/dev/null || true
kubectl label ns openshell \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite

# ── Step 2: Sandbox CRD + controller ──────────────────────────────────
echo "=== Step 2: Installing Sandbox CRD ==="
kubectl apply -f "$OPENSHELL_REPO/deploy/kube/manifests/agent-sandbox.yaml"

# ── Step 3: OpenShift SCCs ────────────────────────────────────────────
echo "=== Step 3: Granting OpenShift SCCs ==="
kubectl create clusterrolebinding openshell-sa-anyuid \
  --clusterrole=system:openshift:scc:anyuid \
  --serviceaccount=openshell:openshell 2>/dev/null || true
kubectl create clusterrolebinding openshell-sa-privileged \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=openshell:openshell 2>/dev/null || true
kubectl create clusterrolebinding openshell-default-privileged \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=openshell:default 2>/dev/null || true
kubectl create clusterrolebinding agent-sandbox-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=agent-sandbox-system:agent-sandbox-controller 2>/dev/null || true

# Also grant privileged to the sandbox service account created by Helm
kubectl create clusterrolebinding openshell-sandbox-privileged \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=openshell:openshell-sandbox 2>/dev/null || true

# ── Step 4: Pull secret (optional) ───────────────────────────────────
if [[ -f "$SCRIPT_DIR/quay-pull-secret.yaml" ]]; then
  echo "=== Step 4: Applying pull secret ==="
  kubectl apply -n openshell -f "$SCRIPT_DIR/quay-pull-secret.yaml"
fi

# ── Step 5: Helm install gateway ──────────────────────────────────────
echo "=== Step 5: Deploying gateway via Helm ==="

# Resolve image tag — the local chart's appVersion is 0.0.0 (dev placeholder),
# so we default to the latest release tag when no override is provided.
if [[ -z "${GATEWAY_IMAGE_TAG:-}" ]]; then
  GATEWAY_IMAGE_TAG=$(gh api repos/NVIDIA/OpenShell/releases/latest --jq '.tag_name' 2>/dev/null | sed 's/^v//' || echo "latest")
  echo "  Resolved image tag: $GATEWAY_IMAGE_TAG"
fi

HELM_ARGS=(
  --set server.sandboxImagePullPolicy=Always
  --set server.dbUrl="sqlite:/var/openshell/openshell.db"
  --set pkiInitJob.enabled=true
  --set pkiInitJob.serverDnsNames[0]=openshell.openshell.svc.cluster.local
  --set service.type=ClusterIP
  --set image.tag="$GATEWAY_IMAGE_TAG"
  --set image.pullPolicy=Always
  --set supervisor.image.tag="$GATEWAY_IMAGE_TAG"
  --set server.auth.allowUnauthenticatedUsers=true
)

[[ -n "${GATEWAY_IMAGE_REPO:-}" ]] && HELM_ARGS+=(--set image.repository="$GATEWAY_IMAGE_REPO")
[[ -n "${SUPERVISOR_IMAGE_REPO:-}" ]] && HELM_ARGS+=(--set supervisor.image.repository="$SUPERVISOR_IMAGE_REPO")
[[ -n "${SANDBOX_IMAGE:-}" ]]      && HELM_ARGS+=(--set server.sandboxImage="$SANDBOX_IMAGE")
[[ -n "${PULL_SECRET:-}" ]]        && HELM_ARGS+=(--set imagePullSecrets[0].name="$PULL_SECRET")

helm upgrade --install openshell "$OPENSHELL_REPO/deploy/helm/openshell" -n openshell \
  "${HELM_ARGS[@]}"

echo "=== Waiting for gateway ==="
kubectl rollout status statefulset/openshell -n openshell --timeout=180s

# ── Step 6: Configure local CLI gateway ───────────────────────────────
echo "=== Step 6: Configuring local CLI gateway ==="
GW_DIR="$HOME/.config/openshell/gateways/$GATEWAY_NAME"
MTLS_DIR="$GW_DIR/mtls"
mkdir -p "$MTLS_DIR"

kubectl get secret openshell-client-tls -n openshell \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$MTLS_DIR/ca.crt"
kubectl get secret openshell-client-tls -n openshell \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$MTLS_DIR/tls.crt"
kubectl get secret openshell-client-tls -n openshell \
  -o jsonpath='{.data.tls\.key}' | base64 -d > "$MTLS_DIR/tls.key"

cat > "$GW_DIR/metadata.json" <<EOF
{"name":"$GATEWAY_NAME","gateway_endpoint":"https://127.0.0.1:18443","is_remote":false,"gateway_port":18443,"auth_mode":"mtls"}
EOF

echo ""
echo "════════════════════════════════════════════════════"
echo "  OpenShell deployed successfully!"
echo "════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo ""
echo "  1. Start port-forward:"
echo "     kubectl port-forward svc/openshell -n openshell 18443:8080"
echo ""
echo "  2. Register providers (credentials for sandboxes):"
echo "     ./setup-providers.sh"
echo ""
echo "  3. Launch a sandbox:"
echo "     ./ocp-sandbox.sh --name my-agent"
echo ""

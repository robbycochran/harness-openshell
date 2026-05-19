#!/usr/bin/env bash
# Deploy OpenShell to an OpenShift cluster.
# Assumes: KUBECONFIG set, kubectl/helm on PATH, quay.io images already pushed.
#
# Usage:
#   ./deploy.sh                           # full deploy
#   ./deploy.sh --kubeconfig ./kubeconfig  # explicit kubeconfig
#   ./deploy.sh --skip-images             # skip image build (use existing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse args
SKIP_IMAGES=true  # images are pre-built on quay.io
while [[ $# -gt 0 ]]; do
  case $1 in
    --kubeconfig) export KUBECONFIG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Require OpenShell repo to be cloned alongside this harness
OPENSHELL_REPO="${OPENSHELL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)/OpenShell}"
if [[ ! -d "$OPENSHELL_REPO/deploy/helm/openshell" ]]; then
  echo "OpenShell repo not found at $OPENSHELL_REPO"
  echo "Set OPENSHELL_REPO or clone NVIDIA/OpenShell alongside this repo"
  exit 1
fi

echo "Using OpenShell repo: $OPENSHELL_REPO"
echo "Using KUBECONFIG: ${KUBECONFIG:-default}"
echo ""

# ── Step 1: Namespace ──
echo "=== Creating namespace ==="
kubectl create ns openshell 2>/dev/null || true
kubectl label ns openshell pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns openshell pod-security.kubernetes.io/warn=privileged --overwrite

# ── Step 2: Sandbox CRD + controller ──
echo "=== Installing Sandbox CRD ==="
kubectl apply -f "$OPENSHELL_REPO/deploy/kube/manifests/agent-sandbox.yaml"

# ── Step 3: SCCs ──
echo "=== Granting SCCs ==="
kubectl create clusterrolebinding openshell-sa-anyuid --clusterrole=system:openshift:scc:anyuid --serviceaccount=openshell:openshell 2>/dev/null || true
kubectl create clusterrolebinding openshell-sa-privileged --clusterrole=system:openshift:scc:privileged --serviceaccount=openshell:openshell 2>/dev/null || true
kubectl create clusterrolebinding openshell-default-privileged --clusterrole=system:openshift:scc:privileged --serviceaccount=openshell:default 2>/dev/null || true
kubectl create clusterrolebinding agent-sandbox-admin --clusterrole=cluster-admin --serviceaccount=agent-sandbox-system:agent-sandbox-controller 2>/dev/null || true

# ── Step 4: TLS certificates ──
echo "=== Generating TLS certificates ==="
TLSDIR="$HOME/.openshell-ocp-tls"
mkdir -p "$TLSDIR"

if [[ ! -f "$TLSDIR/ca.crt" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLSDIR/ca.key" -out "$TLSDIR/ca.crt" -days 365 -subj "/CN=openshell-ca" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$TLSDIR/server.key" -out "$TLSDIR/server.csr" \
    -subj "/CN=openshell.openshell.svc.cluster.local" \
    -addext "subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1" 2>/dev/null
  openssl x509 -req -in "$TLSDIR/server.csr" -CA "$TLSDIR/ca.crt" -CAkey "$TLSDIR/ca.key" -CAcreateserial \
    -out "$TLSDIR/server.crt" -days 365 \
    -extfile <(echo "subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1") 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -keyout "$TLSDIR/client.key" -out "$TLSDIR/client.csr" -subj "/CN=openshell-client" 2>/dev/null
  openssl x509 -req -in "$TLSDIR/client.csr" -CA "$TLSDIR/ca.crt" -CAkey "$TLSDIR/ca.key" -CAcreateserial \
    -out "$TLSDIR/client.crt" -days 365 2>/dev/null
  echo "  Generated new certs at $TLSDIR"
else
  echo "  Using existing certs at $TLSDIR"
fi

# ── Step 5: K8s secrets ──
echo "=== Creating K8s secrets ==="
kubectl create secret tls openshell-server-tls -n openshell --cert="$TLSDIR/server.crt" --key="$TLSDIR/server.key" 2>/dev/null || true
kubectl create secret generic openshell-server-client-ca -n openshell --from-file=ca.crt="$TLSDIR/ca.crt" 2>/dev/null || true
kubectl create secret generic openshell-client-tls -n openshell --from-file=ca.crt="$TLSDIR/ca.crt" --from-file=tls.crt="$TLSDIR/client.crt" --from-file=tls.key="$TLSDIR/client.key" 2>/dev/null || true
kubectl create secret generic openshell-ssh-handshake -n openshell --from-literal=secret="$(openssl rand -hex 32)" 2>/dev/null || true
kubectl apply -n openshell -f "$SCRIPT_DIR/quay-pull-secret.yaml" 2>/dev/null || true

# Credential secrets — create only if they don't exist
kubectl get secret github-token -n openshell >/dev/null 2>&1 || echo "WARNING: github-token secret missing — create manually"
kubectl get secret atlassian-creds -n openshell >/dev/null 2>&1 || echo "WARNING: atlassian-creds secret missing — create manually"
kubectl get secret gws-credentials -n openshell >/dev/null 2>&1 || echo "WARNING: gws-credentials secret missing — create manually"
kubectl get secret gcp-adc -n openshell >/dev/null 2>&1 || echo "WARNING: gcp-adc secret missing — create manually"

# ── Step 6: Supervisor DaemonSet ──
echo "=== Deploying supervisor DaemonSet ==="
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: openshell-supervisor-installer
  namespace: openshell
spec:
  selector:
    matchLabels:
      app: openshell-supervisor-installer
  template:
    metadata:
      labels:
        app: openshell-supervisor-installer
    spec:
      serviceAccountName: default
      imagePullSecrets:
      - name: quay-pull-secret
      initContainers:
      - name: install
        image: quay.io/rcochran/scratch:openshell-supervisor-dev
        command: ["sh", "-c", "mkdir -p /host/opt/openshell/bin && cp /usr/local/bin/openshell-sandbox /host/opt/openshell/bin/openshell-sandbox && chmod 755 /host/opt/openshell/bin/openshell-sandbox && chcon -t container_file_t /host/opt/openshell/bin && chcon -t container_file_t /host/opt/openshell/bin/openshell-sandbox && echo installed"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
      containers:
      - name: pause
        image: registry.k8s.io/pause:3.10
      volumes:
      - name: host-root
        hostPath:
          path: /
      tolerations:
      - operator: Exists
EOF

# ── Step 7: Helm install gateway ──
echo "=== Deploying gateway via Helm ==="
helm upgrade --install openshell "$OPENSHELL_REPO/deploy/helm/openshell" -n openshell \
  --set image.repository=quay.io/rcochran/scratch \
  --set image.tag=openshell-gateway-dev \
  --set image.pullPolicy=Always \
  --set imagePullSecrets[0].name=quay-pull-secret \
  --set server.sandboxImage="quay.io/rcochran/scratch:openshell-sandbox-base" \
  --set server.sandboxImagePullPolicy=Always \
  --set server.grpcEndpoint="https://openshell.openshell.svc.cluster.local:8080" \
  --set server.dbUrl="sqlite:/var/openshell/openshell.db" \
  --set service.type=ClusterIP

echo "=== Waiting for gateway ==="
kubectl rollout status statefulset/openshell -n openshell --timeout=120s

# ── Step 8: Gateway config ──
echo "=== Configuring CLI gateway ==="
mkdir -p "$HOME/.config/openshell/gateways/ocp/mtls"
cp "$TLSDIR/ca.crt" "$HOME/.config/openshell/gateways/ocp/mtls/"
cp "$TLSDIR/client.crt" "$HOME/.config/openshell/gateways/ocp/mtls/tls.crt"
cp "$TLSDIR/client.key" "$HOME/.config/openshell/gateways/ocp/mtls/tls.key"
cat > "$HOME/.config/openshell/gateways/ocp/metadata.json" <<'GWEOF'
{"name":"ocp","gateway_endpoint":"https://127.0.0.1:18443","is_remote":false,"gateway_port":18443,"auth_mode":"mtls"}
GWEOF

echo ""
echo "════════════════════════════════════════════════════"
echo "  OpenShell deployed successfully!"
echo "════════════════════════════════════════════════════"
echo ""
echo "Start port-forward:"
echo "  kubectl port-forward svc/openshell -n openshell 18443:8080"
echo ""
echo "Launch a sandbox:"
echo "  ./ocp-sandbox.sh --name my-agent"
echo ""

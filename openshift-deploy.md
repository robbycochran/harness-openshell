# Deploy OpenShell to OpenShift

Living document. Updated as we progress through each step.

## Overview

Deploy OpenShell gateway + sandbox infrastructure to an existing OpenShift cluster. This does NOT enable user namespace isolation (PR #983) — it uses the standard privileged sandbox model.

## Prerequisites

- [x] OpenShift cluster with `KUBECONFIG` set: `export KUBECONFIG=$PWD/kubeconfig`
  - OCP 4.21 / K8s 1.34.6 / CRI-O 1.34.6 / RHEL CoreOS 9.6 / kernel 5.14 / x86_64
  - 3 masters + 3 workers (`api.rc-test-fact.ocp.infra.rox.systems:6443`)
  - Default StorageClass: `ssd-csi` (PVCs work)
- [ ] `kubectl`, `helm`, `podman` on PATH
- [ ] OpenShell repo checked out (branch: `rc/openshift-deploy`)
- [ ] Rust toolchain installed (for building binaries)
- [ ] quay.io credentials (see `registry-credentials.md`)

## High-Level Plan

| Step | What | Status |
|------|------|--------|
| 1 | Build x86_64 images (gateway + supervisor) + native CLI | **done** |
| 2 | Create `openshell` namespace + label for privileged pods | **done** |
| 3 | Install Sandbox CRD + controller | **done** |
| 4 | Grant OpenShift SCCs (anyuid for gateway, privileged for sandboxes) | **done** |
| 5 | Generate mTLS certificates + create K8s secrets | **done** (certs at `~/.openshell-ocp-tls/`) |
| 6 | Push images to quay.io + create imagePullSecret | **done** |
| 7 | Install supervisor binary on nodes via DaemonSet (uses image from step 6) | **done** (6/6 nodes) |
| 8 | Deploy gateway with Helm | **done** (openshell-0 Running) |
| 9 | Configure CLI with mTLS + port-forward | **done** |
| 10 | Verify: create a sandbox and run a command | **done** |

## Step 1: Build images (cross-compile for x86_64)

Building on Apple Silicon for x86_64 nodes. The Dockerfile requires BuildKit (cache mounts, `$BUILDPLATFORM`), so use Docker (OrbStack) not podman. The Dockerfile handles Rust cross-compilation internally via `cross-build.sh`.

```shell
# Login to quay.io (podman for push, Docker for build)
podman login -u "rcochran+rcochran_quay_scratch" \
  -p "1Q3TUPVODGOU0UE1KM7XQJ8SNR9JV042JVDNIQ88XWUGRRHZ5183CON2N87VS5ED" quay.io

# Gateway image (Docker BuildKit)
DOCKER_BUILDKIT=1 docker build --platform linux/amd64 \
  -f deploy/docker/Dockerfile.images --target gateway \
  -t quay.io/rcochran/scratch:openshell-gateway-dev .

# Supervisor image (reuses cached Rust deps from gateway build)
DOCKER_BUILDKIT=1 docker build --platform linux/amd64 \
  -f deploy/docker/Dockerfile.images --target supervisor \
  -t quay.io/rcochran/scratch:openshell-supervisor-dev .
```

Build the CLI locally (needs Rust 1.85+ for edition 2024 — install via `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`):

```shell
cargo build -p openshell-cli
```

## Step 2: Create namespace

```shell
kubectl create ns openshell
kubectl label ns openshell pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl label ns openshell pod-security.kubernetes.io/warn=privileged --overwrite
```

## Step 3: Install Sandbox CRD + controller

```shell
kubectl apply -f deploy/kube/manifests/agent-sandbox.yaml
```

This creates the `Sandbox` CRD (`agents.x-k8s.io/v1alpha1`) and deploys the controller in `agent-sandbox-system` namespace.

## Step 4: Grant SCCs

Gateway needs `anyuid` (runs as UID 1000). Sandbox pods need `privileged` (SYS_ADMIN, NET_ADMIN, SYS_PTRACE, SYSLOG + hostPath).

```shell
# Gateway SA
kubectl create clusterrolebinding openshell-sa-anyuid \
  --clusterrole=system:openshift:scc:anyuid \
  --serviceaccount=openshell:openshell

# Sandbox pods via openshell SA
kubectl create clusterrolebinding openshell-sa-privileged \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=openshell:openshell

# Sandbox pods via default SA
kubectl create clusterrolebinding openshell-default-privileged \
  --clusterrole=system:openshift:scc:privileged \
  --serviceaccount=openshell:default

# Sandbox CRD controller needs cluster-admin for ownerReferences
kubectl create clusterrolebinding agent-sandbox-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=agent-sandbox-system:agent-sandbox-controller
```

## Step 5: Generate mTLS certificates + secrets

```shell
TLSDIR=$(mktemp -d)

# CA
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout $TLSDIR/ca.key -out $TLSDIR/ca.crt \
  -days 365 -subj "/CN=openshell-ca" 2>/dev/null

# Server cert (SANs cover in-cluster DNS + localhost for port-forward)
openssl req -newkey rsa:2048 -nodes \
  -keyout $TLSDIR/server.key -out $TLSDIR/server.csr \
  -subj "/CN=openshell.openshell.svc.cluster.local" \
  -addext "subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1" 2>/dev/null

openssl x509 -req -in $TLSDIR/server.csr \
  -CA $TLSDIR/ca.crt -CAkey $TLSDIR/ca.key -CAcreateserial \
  -out $TLSDIR/server.crt -days 365 \
  -extfile <(echo "subjectAltName=DNS:openshell.openshell.svc.cluster.local,DNS:openshell,DNS:localhost,IP:127.0.0.1") 2>/dev/null

# Client cert
openssl req -newkey rsa:2048 -nodes \
  -keyout $TLSDIR/client.key -out $TLSDIR/client.csr \
  -subj "/CN=openshell-client" 2>/dev/null

openssl x509 -req -in $TLSDIR/client.csr \
  -CA $TLSDIR/ca.crt -CAkey $TLSDIR/ca.key -CAcreateserial \
  -out $TLSDIR/client.crt -days 365 2>/dev/null

# Create K8s secrets
kubectl create secret tls openshell-server-tls -n openshell \
  --cert=$TLSDIR/server.crt --key=$TLSDIR/server.key

kubectl create secret generic openshell-server-client-ca -n openshell \
  --from-file=ca.crt=$TLSDIR/ca.crt

kubectl create secret generic openshell-client-tls -n openshell \
  --from-file=ca.crt=$TLSDIR/ca.crt \
  --from-file=tls.crt=$TLSDIR/client.crt \
  --from-file=tls.key=$TLSDIR/client.key

kubectl create secret generic openshell-ssh-handshake -n openshell \
  --from-literal=secret=$(openssl rand -hex 32)
```

Note: `openshell-client-tls` must be generic (not `kubernetes.io/tls`) because it needs `ca.crt` in addition to `tls.crt` and `tls.key`.

## Step 6: Push images to quay.io + create imagePullSecret

Push the images built in step 1, plus pull and re-tag the sandbox base image:

```shell
# Push gateway and supervisor (built in step 1)
podman push quay.io/rcochran/scratch:openshell-gateway-dev
podman push quay.io/rcochran/scratch:openshell-supervisor-dev

# Pull the sandbox base image (multi-arch, will get amd64) and re-tag
podman pull --platform linux/amd64 ghcr.io/nvidia/openshell-community/sandboxes/base:latest
podman tag ghcr.io/nvidia/openshell-community/sandboxes/base:latest \
  quay.io/rcochran/scratch:openshell-sandbox-base
podman push quay.io/rcochran/scratch:openshell-sandbox-base
```

Create imagePullSecret so the cluster can pull from quay.io:

```shell
export KUBECONFIG=$PWD/kubeconfig
kubectl apply -n openshell -f architecture/plans/quay-pull-secret.yaml
```

Note: The quay.io repo must be **public**, or you also need the imagePullSecret on the `default` SA for sandbox pods and the `agent-sandbox-system` namespace for the CRD controller.

## Step 7: Install supervisor binary on nodes (DaemonSet)

The supervisor image was built and pushed in steps 1 and 6.

Deploy the installer DaemonSet:

```shell
cat <<EOF | kubectl apply -f -
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
        command:
        - sh
        - -c
        - |
          mkdir -p /host/opt/openshell/bin &&
          cp /usr/local/bin/openshell-sandbox /host/opt/openshell/bin/openshell-sandbox &&
          chmod 755 /host/opt/openshell/bin/openshell-sandbox &&
          chcon -t container_file_t /host/opt/openshell/bin &&
          chcon -t container_file_t /host/opt/openshell/bin/openshell-sandbox &&
          echo installed
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
```

Wait for all pods:

```shell
kubectl get pods -n openshell -l app=openshell-supervisor-installer -o wide
```

The `chcon` step is required on RHEL CoreOS nodes where SELinux enforces file labels.

## Step 8: Deploy gateway with Helm

```shell
helm install openshell deploy/helm/openshell -n openshell \
  --set image.repository=quay.io/rcochran/scratch \
  --set image.tag=gateway-dev \
  --set image.pullPolicy=Always \
  --set imagePullSecrets[0].name=quay-pull-secret \
  --set server.sandboxImage="quay.io/rcochran/scratch:openshell-sandbox-base" \
  --set server.sandboxImagePullPolicy=Always \
  --set server.grpcEndpoint="https://openshell.openshell.svc.cluster.local:8080" \
  --set server.dbUrl="sqlite:/var/openshell/openshell.db" \
  --set service.type=ClusterIP
```

Note: Using the PVC-backed path (`/var/openshell/`) since the cluster has a working default StorageClass (`ssd-csi`). If you hit PVC permission issues, fall back to `--set server.dbUrl="sqlite:/tmp/openshell.db"`.

Wait for the gateway:

```shell
kubectl rollout status statefulset/openshell -n openshell --timeout=120s
```

Note: `server.dbUrl` uses `/tmp` to avoid PVC permission issues. For production, use a PVC-backed path with a properly configured StorageClass.

## Step 9: Configure CLI

Port-forward the gateway:

```shell
nohup kubectl port-forward svc/openshell -n openshell 18443:8080 >/tmp/pf.log 2>&1 &
```

Set up CLI gateway config with mTLS:

```shell
mkdir -p ~/.config/openshell/gateways/ocp/mtls

cp $TLSDIR/ca.crt ~/.config/openshell/gateways/ocp/mtls/
cp $TLSDIR/client.crt ~/.config/openshell/gateways/ocp/mtls/tls.crt
cp $TLSDIR/client.key ~/.config/openshell/gateways/ocp/mtls/tls.key

cat > ~/.config/openshell/gateways/ocp/metadata.json <<'EOF'
{
  "name": "ocp",
  "gateway_endpoint": "https://127.0.0.1:18443",
  "is_remote": false,
  "gateway_port": 18443,
  "auth_mode": "mtls"
}
EOF
```

Verify connectivity:

```shell
OPENSHELL_GATEWAY=ocp target/debug/openshell status
```

Expected:

```
Server Status
  Gateway: ocp
  Server:  https://127.0.0.1:18443
  Status:  Connected
```

## Step 10: Verify — create a sandbox

```shell
export OPENSHELL_GATEWAY=ocp

target/debug/openshell sandbox create --no-bootstrap -- sh -lc \
  "echo '=== id ==='; id; \
   echo '=== hostname ==='; hostname; \
   echo '=== sandbox-ok ==='"
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ErrImageNeverPull` on gateway pod | Image not in internal registry | Push with `podman push --tls-verify=false` |
| `unable to validate against any security context constraint` | Missing SCC grants | Run clusterrolebinding commands from step 4 |
| `cannot set blockOwnerDeletion` | CRD controller lacks RBAC | Grant cluster-admin to controller SA (step 4) |
| `hostPath type check failed: /opt/openshell/bin is not a directory` | Supervisor not installed | Deploy DaemonSet from step 7 |
| `Permission denied` accessing supervisor binary | SELinux blocking hostPath | Ensure `chcon -t container_file_t` was applied (step 7) |
| Gateway `CrashLoopBackOff` with `unable to open database file` | PVC permissions | Use `--set server.dbUrl="sqlite:/tmp/openshell.db"` |
| `dns error: failed to lookup address` from supervisor | DNS not resolving | Use ClusterIP directly in `server.grpcEndpoint` |

## Cleanup

```shell
kubectl delete sandbox --all -n openshell
helm uninstall openshell -n openshell
kubectl delete daemonset openshell-supervisor-installer -n openshell
kubectl delete clusterrolebinding openshell-sa-anyuid openshell-sa-privileged \
  openshell-default-privileged agent-sandbox-admin 2>/dev/null
kubectl delete -f deploy/kube/manifests/agent-sandbox.yaml
kubectl delete ns openshell
pkill -f "port-forward.*18443"
rm -rf ~/.config/openshell/gateways/ocp
```

# Future Ideas

## Policy ConfigMap Mounting

Mount a named ConfigMap at `/etc/openshell/policy.yaml` in sandbox pods so policies become declarative K8s objects. The supervisor already reads from that path as a fallback.

**Implementation (completed but reverted):**
- Added `policy_configmap_name` field to `KubernetesComputeConfig`
- Threaded through `sandbox_to_k8s_spec` → `sandbox_template_to_k8s`
- Mounted ConfigMap volume + volumeMount using the append pattern from `apply_supervisor_sideload`
- Wired Helm value `server.policyConfigMap` and env var `OPENSHELL_SANDBOX_POLICY_CONFIGMAP`
- All tests passed

**Why reverted:** Adds complexity when `--policy` flag on sandbox create already works. Revisit when namespace-based profiles are needed (different policies per namespace without per-sandbox flags).

**Files that were modified:** `config.rs`, `driver.rs`, `main.rs` (K8s driver), `config.rs` (core), `lib.rs`, `cli.rs` (server), `values.yaml`, `statefulset.yaml` (Helm)

## Agent Observability (Loki + Grafana or PVC viewer)

See `agent-observability-spike.md` for full architecture.

## In-Cluster Agent Scheduler (CronJobs)

Launcher pod with OpenShell CLI that creates sandboxes on schedule. See conversation notes.

## Git-Backed Agent Memory

Persistent memory across sessions via a private git repo. Clone at startup, push on exit.

## Web UI for Sandbox Sessions

ttyd/gotty exposing a terminal session as a web page, or a custom viewer streaming Claude JSONL.

## Scoped Deploy Kubeconfig

ServiceAccount with namespace-admin for test namespaces, mounted into sandboxes for agent-driven deployment.

## Direct Secret Mounting into Sandbox Pods

**Priority: High — security improvement**

Currently, `ocp-sandbox.sh` extracts credentials from K8s secrets via `kubectl get secret | base64 -d` onto the local machine, then injects them into the sandbox via the startup script. Credentials transit through the user's Mac in process memory and end up as plaintext files inside the sandbox (`.openshell-env`, `.claude.json`).

**Better approach:** Mount K8s secrets directly as volumes into sandbox pods, the same way `openshell-client-tls` is already mounted at `/etc/openshell-tls/client/`. Credentials go straight from etcd to the pod — never leave the cluster.

**Secrets to mount:**
- `github-token` → env var or file at `/etc/openshell-creds/github`
- `atlassian-creds` → env vars or files at `/etc/openshell-creds/atlassian/`
- `gws-credentials` → files at `/etc/openshell-creds/gws/`
- `gcp-adc` → file at `/etc/openshell-creds/adc.json`

**Requires:** Adding extra volume mount support to the OpenShell K8s driver (`crates/openshell-driver-kubernetes/src/driver.rs`). The implementation was designed and tested (policy ConfigMap work) but reverted. Same pattern applies — add a config field for additional secret volumes, thread through `sandbox_template_to_k8s`, mount into the pod spec.

**Workaround until then:** The current kubectl-extract-and-inject approach via `ocp-sandbox.sh`.

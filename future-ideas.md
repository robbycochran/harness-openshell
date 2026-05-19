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

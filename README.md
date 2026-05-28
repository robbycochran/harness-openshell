# OpenShell Harness for OpenShift

Deploy OpenShell sandboxes on OpenShift with Claude Code (Vertex AI), Atlassian MCP, Google Workspace, and GitHub integrations.

## What This Is

A deployment harness for running AI agent sandboxes on OpenShift using [OpenShell](https://github.com/NVIDIA/OpenShell). Each sandbox gets:

- **Claude Code** via Google Vertex AI (or direct Anthropic API)
- **Jira/Confluence** via mcp-atlassian MCP server
- **Gmail, Calendar, Drive** via gws CLI
- **GitHub** via gh CLI (pre-authenticated)
- Network policy enforcement per sandbox
- Persistent workspace across reconnects

## Prerequisites

- OpenShift cluster with `KUBECONFIG` set
- `kubectl`, `helm` on PATH
- OpenShell CLI (`openshell`) installed or built from source
- NVIDIA/OpenShell repo cloned alongside this repo (for the Helm chart)
- `gcloud auth application-default login` completed (if using Vertex AI)

## Quick Start

```shell
# 1. Deploy OpenShell to the cluster (Helm chart + CRD + SCCs)
./deploy.sh

# 2. Start port-forward to the gateway
kubectl port-forward svc/openshell -n openshell 18443:8080

# 3. Register provider credentials (GitHub, Anthropic, GCP ADC)
export GITHUB_TOKEN="ghp_..."
# ADC secrets are auto-extracted from your local ADC file by setup-providers.sh
./setup-providers.sh

# 4. Launch an interactive Claude sandbox
#    Atlassian creds are passed directly (not via provider)
export JIRA_URL="https://mysite.atlassian.net"
export JIRA_USERNAME="user@example.com"
export JIRA_API_TOKEN="ATATT..."
./ocp-sandbox.sh --name my-agent
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Deploy OpenShell (namespace, CRD, SCCs, Helm chart) |
| `setup-providers.sh` | Register credentials with the OpenShell provider system |
| `ocp-sandbox.sh` | Launch/rejoin Claude sandboxes with all integrations |
| `vertex-policy.yaml` | Network policy for sandbox egress |
| `credentials.md` | Credential flows, mechanisms, and rotation guide |
| `sandbox-CLAUDE.md` | Agent instructions injected into sandboxes |
| `verify-integrations.py` | Integration test script for all tools |
| `future-ideas.md` | Roadmap (observability, CronJobs, web UI, memory) |

## Credentials

See [credentials.md](credentials.md) for the full credential reference — how each credential is stored, transported, and consumed in sandboxes.

**Quick summary:**

| Credential | Mechanism | Setup |
|------------|-----------|-------|
| GitHub | Provider (Bearer auth) | `setup-providers.sh` |
| GCP ADC | Provider (decomposed, L7 body rewrite) | `setup-providers.sh` |
| Anthropic | Provider (Bearer auth) | `setup-providers.sh` (optional, not needed for Vertex) |
| Atlassian | Literal env vars (Basic auth) | Set `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` before `ocp-sandbox.sh` |
| Google Workspace | File upload | Pre-authenticate with `gws auth login` |

## Sandbox Usage

```shell
# Interactive Claude session
./ocp-sandbox.sh --name dev

# Reconnect to a running sandbox
./ocp-sandbox.sh --rejoin dev

# Shell mode (type 'claude' to start)
./ocp-sandbox.sh --name debug --shell

# Delete sandbox after exit
./ocp-sandbox.sh --name ephemeral --no-keep
```

## Customizing Images

Override image sources with environment variables:

```shell
export GATEWAY_IMAGE_REPO=quay.io/myrepo/openshell-gateway
export GATEWAY_IMAGE_TAG=v1.0.0
export SUPERVISOR_IMAGE_REPO=quay.io/myrepo/openshell-supervisor
export SANDBOX_IMAGE=quay.io/myrepo/sandbox-base:latest
export PULL_SECRET=my-registry-secret
./deploy.sh
```

By default, upstream images from `ghcr.io/nvidia/openshell/` are used.

## Architecture

```
Your Mac                         OpenShift Cluster
┌──────────┐   port-forward    ┌──────────────────────────────┐
│ openshell├───────────────────▶│ Gateway (StatefulSet)         │
│ CLI      │   mTLS :18443     │   ├─ gRPC API                 │
│          │                   │   ├─ SSH tunnel               │
│          │                   │   ├─ Provider credential store │
│          │                   │   └─ Sandbox lifecycle mgmt   │
└──────────┘                   │                               │
                               │ Sandbox Pods                  │
                               │   ├─ Claude Code              │
                               │   ├─ mcp-atlassian            │
                               │   ├─ gws CLI                  │
                               │   ├─ gh CLI                   │
                               │   └─ Network proxy            │
                               │                               │
                               │ Supervisor (init-container)   │
                               │   └─ sideloaded per sandbox   │
                               └──────────────────────────────┘
```

### Key Differences from Manual Deployment

This harness relies on the official OpenShell Helm chart, which handles:

- **TLS/PKI** — auto-generated via a pre-install certgen job (no manual OpenSSL)
- **Supervisor** — sideloaded into each sandbox pod as an init-container (no DaemonSet)
- **Credentials** — managed by the provider system with refresh support (no raw K8s secrets)
- **Gateway config** — TOML-based ConfigMap rendered by Helm

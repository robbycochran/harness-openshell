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

# 3. Register your credentials as providers
export GITHUB_TOKEN="ghp_..."
export JIRA_URL="https://mysite.atlassian.net"
export JIRA_USERNAME="user@example.com"
export JIRA_API_TOKEN="ATATT..."
./setup-providers.sh

# 4. Launch an interactive Claude sandbox
./ocp-sandbox.sh --name my-agent
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Deploy OpenShell (namespace, CRD, SCCs, Helm chart) |
| `setup-providers.sh` | Register credentials with the OpenShell provider system |
| `ocp-sandbox.sh` | Launch/rejoin Claude sandboxes with all integrations |
| `vertex-policy.yaml` | Network policy for sandbox egress |
| `sandbox-CLAUDE.md` | Agent instructions injected into sandboxes |
| `verify-integrations.py` | Integration test script for all tools |
| `future-ideas.md` | Roadmap (observability, CronJobs, web UI, memory) |

## How Credentials Work

This harness uses the **OpenShell provider system** instead of raw K8s secrets. Credentials are:

1. Registered once via `setup-providers.sh` (stored in the gateway database)
2. Automatically injected as environment variables into sandbox pods
3. Attached to sandboxes with `--provider` flags

| Provider | Type | Env Vars Injected |
|----------|------|-------------------|
| `github` | github | `GITHUB_TOKEN` |
| `atlassian` | generic | `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` |
| `anthropic` | anthropic | `ANTHROPIC_API_KEY` |

File-based credentials (GCP ADC, GWS OAuth) are uploaded at sandbox creation time via `--upload`.

### Updating Credentials

```shell
# Update a single credential
openshell provider update github --credential GITHUB_TOKEN="ghp_new_token"

# Re-discover from environment
export GITHUB_TOKEN="ghp_new_token"
openshell provider update github --from-existing

# Or re-run the setup script
./setup-providers.sh
```

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

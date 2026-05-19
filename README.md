# OpenShell Harness for OpenShift

Deploy OpenShell sandboxes on OpenShift with Claude Code (Vertex AI), Atlassian MCP, Google Workspace, and GitHub integrations.

## What This Is

A harness for running AI agent sandboxes on an OpenShift cluster using [OpenShell](https://github.com/NVIDIA/OpenShell). Each sandbox gets:

- **Claude Code** via Google Vertex AI (no Anthropic API key needed)
- **Jira/Confluence** via mcp-atlassian MCP server
- **Gmail, Calendar, Drive** via gws CLI
- **GitHub** via gh CLI (pre-authenticated)
- Network policy enforcement per sandbox
- Persistent workspace across reconnects

## Prerequisites

- OpenShift cluster with `KUBECONFIG` set
- `kubectl`, `helm` on PATH
- Docker or OrbStack (for building images — BuildKit required)
- Rust toolchain 1.85+ (for building the OpenShell CLI)
- `gcloud auth application-default login` completed (for Vertex AI)
- quay.io registry credentials

## Quick Start

```shell
# 1. Deploy OpenShell to the cluster
./deploy.sh

# 2. Launch an interactive Claude sandbox
./ocp-sandbox.sh --name my-agent

# 3. Once connected, type 'claude' to start
```

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Full OpenShell deployment (namespace, CRD, SCCs, TLS, supervisor, Helm) |
| `ocp-sandbox.sh` | Launch/rejoin Claude sandboxes with all integrations |
| `vertex-policy.yaml` | Network policy for sandbox egress |
| `sandbox-CLAUDE.md` | Agent instructions injected into sandboxes |
| `sandbox-harness.md` | Operations doc (credential rotation, architecture) |
| `verify-integrations.py` | Integration test script for all tools |
| `openshift-deploy.md` | Step-by-step deployment guide |
| `future-ideas.md` | Roadmap (observability, CronJobs, web UI, memory) |

## Credentials (K8s Secrets)

All credentials are stored as K8s secrets in the `openshell` namespace:

| Secret | Purpose |
|--------|---------|
| `openshell-server-tls` | Gateway TLS cert |
| `openshell-server-client-ca` | CA for mTLS |
| `openshell-client-tls` | Client mTLS cert |
| `openshell-ssh-handshake` | SSH HMAC key |
| `quay-pull-secret` | Registry auth |
| `github-token` | GitHub PAT |
| `atlassian-creds` | Jira URL, email, API token |
| `gws-credentials` | Google Workspace OAuth |
| `gcp-adc` | Vertex AI Application Default Credentials |

See `sandbox-harness.md` for rotation and revocation instructions.

## Container Images

All images pushed to `quay.io/rcochran/scratch` with tags:

| Tag | Source | Purpose |
|-----|--------|---------|
| `openshell-gateway-dev` | `Dockerfile.images --target gateway` | Gateway server |
| `openshell-supervisor-dev` | `Dockerfile.images --target supervisor` | Sandbox supervisor |
| `openshell-sandbox-base` | `ghcr.io/nvidia/openshell-community/sandboxes/base` | Sandbox base image |

## Sandbox Usage

```shell
# Interactive Claude session
./ocp-sandbox.sh --name dev

# Keep sandbox alive after disconnect
./ocp-sandbox.sh --name dev --keep

# Reconnect to a running sandbox
./ocp-sandbox.sh --rejoin dev

# Shell without Claude
./ocp-sandbox.sh --name debug --shell
```

## Architecture

```
Your Mac                         OpenShift Cluster
┌──────────┐   port-forward    ┌─────────────────────────┐
│ openshell├───────────────────▶│ Gateway (StatefulSet)    │
│ CLI      │   mTLS :18443     │   ├─ gRPC API            │
└──────────┘                   │   ├─ SSH tunnel          │
                               │   └─ sandbox lifecycle   │
                               │                          │
                               │ Sandbox Pods             │
                               │   ├─ Claude Code         │
                               │   ├─ mcp-atlassian       │
                               │   ├─ gws CLI             │
                               │   ├─ gh CLI              │
                               │   └─ Network proxy       │
                               │                          │
                               │ Supervisor DaemonSet     │
                               │   └─ /opt/openshell/bin  │
                               └─────────────────────────┘
```

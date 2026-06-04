# OpenShell Harness

Deploy AI agent sandboxes on Podman (local) or OpenShift using [OpenShell](https://github.com/NVIDIA/OpenShell). Each sandbox gets:

- **Claude Code** via Google Vertex AI (`inference.local` routing)
- **Jira/Confluence** via mcp-atlassian MCP server
- **Gmail, Calendar, Drive** via gws CLI
- **GitHub** via gh CLI
- Network policy enforcement per sandbox

## Prerequisites

- [OpenShell CLI](https://github.com/NVIDIA/OpenShell) (`openshell`)
- Python 3.11+ (for TOML parsing)
- Podman (local) or kubectl + helm (OCP)
- `gcloud auth application-default login` (for Vertex AI)

Optional: `gws` CLI (Google Workspace), `bats` (for unit tests)

## Setup

```bash
# Add harness CLI to PATH
export PATH="$PWD/bin:$PATH"

# See available commands
harness
```

## Quick Start (Local)

```bash
# Install OpenShell if you haven't
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh

# Set credentials
export GITHUB_TOKEN="ghp_..."
export JIRA_API_TOKEN="..."
export ANTHROPIC_VERTEX_PROJECT_ID="my-project"
export CLOUD_ML_REGION="us-east5"

# Create a sandbox (deploys gateway + registers providers if needed)
harness new --local
```

## Quick Start (OpenShift)

```bash
# Create a sandbox on the cluster
harness new --remote
```

## CLI Reference

```
harness new [--local|--remote] [--profile NAME] [SANDBOX_NAME]
    Create a new sandbox. Auto-deploys gateway and registers providers if needed.

harness connect [SANDBOX_NAME]
    Reconnect to a running sandbox.

harness deploy [--local|--remote]
    Deploy or verify the gateway without creating a sandbox.

harness teardown [--sandboxes] [--providers] [--k8s]
    Tear down sandboxes, providers, or k8s resources.

harness preflight
    Check environment prerequisites.

harness providers
    Register providers with the gateway.

harness test [podman|ocp|all] [--full]
    End-to-end validation.
```

## Profiles

Sandboxes are configured via `profiles/*.toml`:

```toml
# profiles/default.toml
name = "agent"
image = "quay.io/rcochran/openshell:sandbox"
command = "claude --bare"
providers = ["github", "vertex-local", "atlassian"]

[env]
ANTHROPIC_BASE_URL = "https://inference.local"
JIRA_URL = "https://mysite.atlassian.net"
```

Use a specific profile: `harness new --profile coder`

## Testing

```bash
harness test podman --full    # full local validation
harness test ocp --full       # full OCP validation
bats test/preflight.bats      # unit tests (29 tests)
make test                     # build images + test both
```

## Files

| Path | Purpose |
|------|---------|
| `bin/harness` | CLI entry point |
| `bin/scripts/` | Subcommand scripts (new, deploy, teardown, etc.) |
| `bin/scripts/lib/` | Shared libraries (profile parsing, providers, common) |
| `profiles/default.toml` | Default sandbox profile |
| `providers.toml` | Provider definitions (env/file/check inputs) |
| `openshell.toml` | Which providers to enable, upstream version pin |
| `sandbox/` | Sandbox image (Dockerfile, startup.sh, policy.yaml, CLAUDE.md) |
| `sandbox/launcher/` | In-cluster launcher image (for OCP sandboxes) |
| `test/` | Tests (preflight.bats, test-flow.sh) |
| `values-ocp.yaml` | Helm values for OpenShift deployment |
| `AGENTS.md` | Project principles and workaround tracking |

## Why Use a Sandbox?

Compared to running Claude Code locally:
- **Credential isolation** — sandbox never sees real API tokens (proxy-resolved placeholders)
- **Network policy** — per-binary egress rules (policy.yaml controls which processes reach which hosts)
- **Reproducible environment** — pinned tool versions in Dockerfile
- **Team sharing** — OCP deployment with mTLS, shared gateway, per-user sandboxes

## Architecture

```
Your Mac                         OpenShift Cluster
┌──────────┐                   ┌──────────────────────────────┐
│ harness  │   OpenShift Route │ Gateway (StatefulSet)         │
│ CLI      ├──────────────────►│   ├─ gRPC API                 │
│          │   TLS passthrough │   ├─ inference.local proxy     │
│          │   mTLS :443       │   ├─ Provider credential store │
└──────────┘                   │   └─ OAuth token refresh       │
                               │                               │
                               │ Sandbox Pods                  │
                               │   ├─ Claude Code → inference  │
                               │   │   .local → Vertex AI      │
                               │   ├─ mcp-atlassian            │
                               │   ├─ gws CLI                  │
                               │   ├─ gh CLI                   │
                               │   └─ Network proxy            │
                               └──────────────────────────────┘
```

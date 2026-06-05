# OpenShell Harness

A gateway harness for [OpenShell](https://github.com/NVIDIA/OpenShell). One command to a working AI agent sandbox — gateway deployed, providers registered, credentials validated, sandbox running.

Without this tool, setting up a sandbox means manually deploying an OpenShell gateway (Helm install, mTLS cert extraction, SCC grants), manually registering providers with credentials scattered across env vars and files, and debugging when credentials expire or proxies misconfigure. The harness handles all of that.

## What it does

The harness wraps `openshell` — it doesn't replace it. It adds orchestration, validation, and configuration management across three domains:

| Domain | What | Config |
|--------|------|--------|
| **Infrastructure** | Deploy the gateway (local Podman or remote OpenShift), Helm, mTLS, RBAC | `openshell.toml` |
| **Providers** | Register credential providers (Vertex AI, GitHub, Atlassian), validate inputs | `providers.toml` |
| **Sandbox** | Create sandboxes from profiles, stage files, connect | `profiles/*.toml` |

Each sandbox gets:
- Claude Code via Vertex AI (`inference.local` gateway routing)
- Jira and Confluence via mcp-atlassian MCP server
- Gmail, Calendar, Drive via gws CLI
- GitHub via gh CLI
- Network policy enforcement per sandbox

## Prerequisites

- [OpenShell CLI](https://github.com/NVIDIA/OpenShell) (`openshell`)
- Podman (local) or kubectl + helm (OpenShift)
- `gcloud auth application-default login` (Vertex AI)

Optional: `gws` CLI (Google Workspace), `bats` (tests)

## Quick Start

```bash
# Set credentials
export GITHUB_TOKEN="ghp_..."
export JIRA_API_TOKEN="..."
export ANTHROPIC_VERTEX_PROJECT_ID="my-project"

# Local — deploy gateway, register providers, create sandbox
harness new --local

# OpenShift — same flow, remote cluster
harness new --remote

# Reconnect to a running sandbox
harness connect
```

## Commands

```
harness new [--local|--remote] [--profile NAME]
    Full flow: deploy gateway + register providers + create sandbox.

harness connect [NAME]
    Reconnect to a running sandbox.

harness deploy [--local|--remote]
    Deploy or verify the gateway without creating a sandbox.

harness providers [--force]
    Register providers with the gateway.

harness preflight [--strict]
    Check environment prerequisites (credentials, CLI tools, gateway).

harness teardown [--sandboxes] [--providers] [--k8s]
    Tear down sandboxes, providers, or cluster resources.
    At least one flag required.
```

## Profiles

Sandboxes are configured via TOML profiles:

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

Use a specific profile: `harness new --profile research`

## Why a sandbox

Compared to running Claude Code locally:

- **Credential isolation** — the sandbox never sees real API tokens (proxy-resolved placeholders)
- **Network policy** — per-binary egress rules control which processes reach which hosts
- **Reproducible environment** — pinned tool versions, same setup across machines and team members
- **Team sharing** — OpenShift deployment with mTLS, shared gateway, per-user sandboxes

## Architecture

```
Your machine                      OpenShift cluster
┌──────────┐                    ┌──────────────────────────────┐
│ harness  │  Route (mTLS)      │ Gateway (StatefulSet)         │
│ CLI      ├───────────────────►│   ├─ gRPC API                 │
│          │                    │   ├─ inference.local proxy     │
└──────────┘                    │   ├─ Provider credential store │
                                │   └─ OAuth token refresh       │
                                │                                │
                                │ Sandbox Pods                   │
                                │   ├─ Claude Code → Vertex AI   │
                                │   ├─ mcp-atlassian             │
                                │   ├─ gws CLI                   │
                                │   ├─ gh CLI                    │
                                │   └─ L7 network proxy          │
                                └──────────────────────────────┘
```

## Project Layout

| Path | Purpose |
|------|---------|
| `main.go`, `cmd/` | CLI commands (Go) |
| `internal/gateway/` | OpenShell CLI wrapper (Gateway interface) |
| `internal/k8s/` | kubectl/helm/oc runner with retry |
| `internal/profile/` | Profile TOML parsing |
| `internal/preflight/` | Provider prerequisite checks |
| `profiles/` | Sandbox profiles (TOML) |
| `providers.toml` | Provider catalog (inputs, prerequisites) |
| `sandbox/` | Sandbox image (Dockerfile, startup, policy, CLAUDE.md) |
| `sandbox/launcher/` | In-cluster launcher for OCP sandboxes |
| `sandbox/profiles/` | OpenShell provider type profiles (YAML) |
| `deploy/` | K8s manifests (RBAC, route) |
| `test/` | Tests (bats preflight, test-flow.sh integration) |

## Testing

```bash
make validate            # full matrix: {bash,go} x {podman,ocp}
make test                # build images + test
bats test/preflight.bats # 29 preflight unit tests
go test ./...            # Go unit tests
```

## Design

The harness is a thin wrapper that should shrink over time. As OpenShell adds native support for features the harness currently bridges (GWS credentials, provider config injection, in-cluster sandbox creation), the custom code gets replaced by upstream. See [AGENTS.md](AGENTS.md) for workaround tracking and [docs/design.md](docs/design.md) for the full design document.

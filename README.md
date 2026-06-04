# OpenShell Harness

Deploy AI agent sandboxes on Podman (local) or OpenShift using [OpenShell](https://github.com/NVIDIA/OpenShell). Each sandbox gets:

- **Claude Code** via Google Vertex AI (`inference.local` routing)
- **Jira/Confluence** via mcp-atlassian MCP server
- **Gmail, Calendar, Drive** via gws CLI
- **GitHub** via gh CLI
- Network policy enforcement per sandbox

## Quick Start (Local)

```bash
# 1. Install OpenShell
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh

# 2. Verify gateway
./deploy-podman.sh

# 3. Register providers (one-time)
export GITHUB_TOKEN="ghp_..."
export JIRA_API_TOKEN="..."
export ANTHROPIC_VERTEX_PROJECT_ID="my-project"
export CLOUD_ML_REGION="us-east5"
./setup-providers.sh

# 4. Launch a sandbox
./sandbox-podman.sh
```

## Quick Start (OpenShift)

```bash
# 1. Deploy gateway to cluster
./deploy-ocp.sh

# 2. Store credentials + register providers
./setup-creds.sh
./setup-providers.sh

# 3. Launch a sandbox
./sandbox-ocp.sh
```

## Agent Configs

Sandboxes are configured via `agents/*.toml`:

```toml
# agents/default.toml
name = "agent"
image = "quay.io/rcochran/openshell:sandbox"
command = "claude --bare"
providers = ["github", "vertex-local", "atlassian"]

[env]
ANTHROPIC_BASE_URL = "https://inference.local"
JIRA_URL = "https://mysite.atlassian.net"
```

Launch with a specific config: `./sandbox-podman.sh research` (uses `agents/research.toml`).

## Testing

```bash
bats test/preflight.bats        # unit tests (29 tests)
./test-flow.sh podman --full    # full local validation
./test-flow.sh ocp --full       # full OCP validation
make test                       # build images + test both
```

## Files

| File | Purpose |
|------|---------|
| `agents/default.toml` | Agent config (image, command, providers, env vars) |
| `providers.toml` | Provider definitions (env/file/check inputs) |
| `openshell.toml` | Which providers to enable, inference model |
| `deploy-podman.sh` | Verify local gateway is running |
| `deploy-ocp.sh` | Deploy OpenShell to OpenShift (Helm + route) |
| `setup-providers.sh` | Register providers with the gateway |
| `setup-creds.sh` | Store GWS + Atlassian config in cluster (OCP only) |
| `sandbox-podman.sh` | Launch sandbox locally |
| `sandbox-ocp.sh` | Launch sandbox on OpenShift |
| `teardown.sh` | Tear down sandboxes, providers, k8s resources |
| `test-flow.sh` | End-to-end validation |
| `openshell-harness-preflight.sh` | Pre-flight environment check |
| `AGENTS.md` | Project principles and workaround tracking |

## Sandbox Usage

```bash
openshell sandbox connect <name>    # reconnect
openshell sandbox list              # list running
openshell sandbox delete <name>     # delete
```

## Architecture

```
Your Mac                         OpenShift Cluster
┌──────────┐                   ┌──────────────────────────────┐
│ openshell│   OpenShift Route │ Gateway (StatefulSet)         │
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

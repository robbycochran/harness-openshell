# OpenShell Harness

An orchestration layer for [OpenShell](https://github.com/NVIDIA/OpenShell) that automates gateway deployment, provider registration, credential validation, and sandbox creation. One command gets you from zero to a running AI agent sandbox on local Podman or remote OpenShift.

## Relationship to OpenShell

The harness wraps `openshell` -- it does not replace it. Every operation delegates to the OpenShell CLI via `exec.Command`. Users can drop to raw `openshell` commands at any time.

The harness automates four things that OpenShell leaves to the user:

- **Gateway deployment** -- OpenShell provides the gateway binary and Helm chart but leaves orchestration to the user (namespace setup, CRDs, SCCs on OpenShift, mTLS cert extraction, Helm values). The harness drives this via config-driven gateway definitions (`gateways/local/`, `gateways/ocp/`, `gateways/kind/`).

- **Provider lifecycle** -- OpenShell manages credentials once registered but does not validate prerequisites or discover credentials from local tooling. The harness adds preflight checks (env vars, files, connectivity probes) and profile-driven provider selection.

- **Credential validation** -- Preflight checks verify credentials are present and valid on the host before registration.

- **Parity across targets** -- A sandbox created locally via Podman behaves identically to one on OpenShift. The harness enforces this by using the same profiles, provider catalog, and validation on both.

As OpenShell adds native support for these workflows, the corresponding harness code shrinks. Every workaround tracks the upstream issue that would eliminate it (see [AGENTS.md](AGENTS.md)).

## How It Compares

| Concern | OpenShell Harness | [Kaiden](https://github.com/openkaiden/kaiden) | [Plandex](https://github.com/plandex-ai/plandex) |
|---------|-------------------|--------|---------|
| **Sandbox runtime** | Delegates entirely to OpenShell | Migrating to OpenShell | None (runs locally) |
| **Entry point** | Container image | Local folder or git URL | Local directory |
| **Provider management** | Preflight validation + registration | Delegates to OpenShell | N/A |
| **Target environments** | Local Podman + remote K8s/OCP | Local only (desktop app) | Local only |
| **Credential isolation** | Proxy-resolved placeholders; sandbox never sees tokens | Delegates to OpenShell | None |
| **Configuration** | TOML profiles + provider catalog | JSON projects (GUI-driven) | YAML plans |

The harness operates at the infrastructure layer -- deploying gateways, registering providers, validating credentials. Kaiden operates at the workspace layer -- selecting which skills, MCP servers, and knowledge bases a workspace gets. They are complementary. See [profile.md](profile.md) for a detailed analysis.

## Three Domains

| Domain | Question | Config | Commands |
|--------|----------|--------|----------|
| **Infrastructure** | How is the gateway deployed? | `gateways/<name>/gateway.toml` | `deploy`, `teardown --k8s` |
| **Providers** | What credentials are available and valid? | `providers.toml` | `providers`, `preflight` |
| **Sandbox** | What sandbox do I want? | `profiles/*.toml` | `up`, `create`, `connect` |

Each domain has its own config, its own code boundary, and its own concerns. A sandbox profile says what providers a sandbox wants. The provider catalog says what exists and how to validate it. The infrastructure layer handles where it all runs.

## Quick Start

```bash
# Install OpenShell CLI
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh

# Authenticate with Google Cloud (Vertex AI inference)
gcloud auth application-default login --project your-gcp-project-id

# Set credentials
export GITHUB_TOKEN="ghp_..."
export JIRA_API_TOKEN="..."
export JIRA_URL="https://mysite.atlassian.net"
export JIRA_USERNAME="you@example.com"

# Build the harness
make cli

# Local -- deploy gateway, register providers, create sandbox
harness up --local

# Remote -- same flow on OpenShift
harness up --remote

# Reconnect to a running sandbox
harness connect
```

Podman is required for local sandboxes. kubectl + helm are required for remote.

## Commands

```
harness up [--local|--remote] [--profile NAME] [--name SANDBOX_NAME]
    Full flow: deploy gateway + register providers + create sandbox + connect.

harness create [--profile NAME] [--name SANDBOX_NAME]
    Validate gateway readiness, check provider prerequisites, and deploy a sandbox.
    Non-interactive -- prints the sandbox name for later connection via harness connect.

harness connect [NAME]
    Reconnect to a running sandbox.

harness deploy [GATEWAY_NAME]
    Deploy or verify a gateway by name (local, ocp, kind).

harness providers [--force]
    Register providers with the gateway.

harness preflight [--strict]
    Validate local environment prerequisites.

harness teardown [--sandboxes] [--providers] [--k8s]
    Tear down resources. At least one flag required.
```

## Profiles

Sandboxes are configured via TOML profiles. A profile defines the sandbox shape -- image, command, which providers to attach, and environment variables.

```toml
# profiles/default.toml
name = "agent"
from = "ghcr.io/robbycochran/harness-openshell:sandbox"
command = "claude --bare"
providers = ["github", "vertex-local", "atlassian"]

[env]
ANTHROPIC_BASE_URL = "https://inference.local"
```

Provider credentials and provider-specific config are provider concerns, not profile concerns. The profile just lists which providers the sandbox wants.

Use a specific profile: `harness up --profile research`

## Provider Catalog

`providers.toml` defines available providers and how to validate them:

```toml
[[providers]]
name = "atlassian"
type = "openshell"
description = "Jira and Confluence (Basic auth resolved by proxy)"
inputs = [
  { key = "JIRA_API_TOKEN", kind = "env", secret = true },
  { key = "JIRA_URL", kind = "env", sandbox = true },
  { key = "JIRA_USERNAME", kind = "env", sandbox = true },
]
```

Providers with `type = "openshell"` are registered with the gateway and managed by OpenShell's credential proxy. Providers with `type = "custom"` are workarounds for integrations OpenShell does not natively support yet -- each tracks its upstream issue. See [PROVIDERS-SPEC.md](PROVIDERS-SPEC.md) for the full schema.

## Architecture

```
Local (Podman)                    Remote (OpenShift)
+-----------+                    +------------------------------+
| harness   |  openshell CLI     | Gateway (StatefulSet)         |
| CLI       +-------------------+|   +- OpenShell API             |
|           |  localhost:17670   |   +- inference.local proxy     |
+-----------+                    |   +- Provider credential store |
                                 |   +- OAuth token refresh       |
       or                        |                                |
                                 | Sandbox Pods                   |
+-----------+  Route (mTLS)      |   +- Claude Code -> Vertex AI  |
| harness   +-------------------+|   +- mcp-atlassian             |
| CLI       |  OCP :443          |   +- gws CLI                   |
+-----------+                    |   +- gh CLI                    |
                                 |   +- L7 network proxy          |
                                 +------------------------------+
```

The harness talks to the gateway via the `openshell` CLI (exec). The Gateway interface abstracts the transport to support a future gRPC path.

Each sandbox gets credential isolation (proxy-resolved placeholders, the sandbox never sees real tokens), per-binary network policy enforcement, and a reproducible toolchain pinned in the container image.

### Launcher (in-cluster sandbox creation)

The launcher is a Kubernetes Job that runs in the target namespace alongside the gateway. It bridges cluster-side secrets into the sandbox.

**Why it exists.** Remote sandboxes on OpenShift need mTLS certificates, GWS credentials, and other secrets that live in the cluster. The harness CLI runs on the user's workstation and does not have access to these secrets. The launcher runs in-cluster where it can mount them directly, then creates and configures the sandbox from there.

**When it runs.** The gateway config (`gateway.toml`) controls this via the `mode` field:

| Mode | When | What happens |
|------|------|-------------|
| `launcher` | Remote/OCP deployments with custom providers that need cluster secrets | Harness submits a Kubernetes Job; the launcher binary does the rest in-cluster |
| `direct` | Local Podman, or remote clusters using only official providers | Harness creates the sandbox directly via the `openshell` CLI -- no Job needed |

The OCP gateway (`gateways/ocp/gateway.toml`) defaults to `mode = "launcher"`. The local and kind gateways default to `mode = "direct"`.

**The flow.** When `harness up --remote` runs:

1. The harness creates a ConfigMap from the selected profile and submits a launcher Job.
2. The launcher pod starts with four volume mounts: the profile ConfigMap, the GWS credentials Secret, the mTLS client certificate Secret, and an optional env ConfigMap.
3. The launcher registers the gateway using the mounted mTLS certs (`openshell gateway add` + metadata patch for mTLS auth).
4. It checks which providers from the profile are already registered on the gateway.
5. It stages credential files (GWS tokens, sandbox env vars) into a temporary directory.
6. It creates the sandbox via `openshell sandbox create` with the profile's image, providers, and a no-op command.
7. It uploads the staged credential files into the sandbox at `/sandbox/.config/openshell/`.
8. It runs the startup script (`/sandbox/startup.sh`) inside the sandbox to finalize configuration.

The launcher source is at `sandbox/launcher/main.go`.

## Project Layout

| Path | Purpose |
|------|---------|
| `main.go`, `cmd/` | CLI commands (Go) |
| `internal/gateway/` | OpenShell CLI wrapper (Gateway interface) |
| `internal/k8s/` | kubectl/helm/oc runner with retry and transient error handling |
| `internal/profile/` | Profile TOML parsing and staging |
| `internal/preflight/` | Provider prerequisite validation |
| `profiles/` | Sandbox profiles (TOML) |
| `providers.toml` | Provider catalog (inputs, prerequisites, upstream tracking) |
| `gateways/` | Per-target gateway configs (`local/`, `ocp/`, `kind/`) |
| `sandbox/` | Sandbox container image (Dockerfile, startup, policy, agent instructions) |
| `sandbox/launcher/` | In-cluster launcher for OCP sandboxes |
| `sandbox/profiles/` | OpenShell provider type profiles (YAML, imported into gateway) |
| `test/` | Tests (bats preflight, test-flow.sh integration) |

## Testing

```bash
make validate-dev        # build dev images + run integration tests
go test ./...            # Go unit tests
bats test/preflight.bats # 29 preflight unit tests
```

## Contributing

See [AGENTS.md](AGENTS.md) for coding guidelines, project principles, and workaround tracking.

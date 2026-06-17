# harness

Declarative configuration harness for [OpenShell](https://github.com/NVIDIA/OpenShell) AI agent sandboxes.

```bash
harness init              # generate a config
harness doctor            # check your environment
harness apply -f harness.yaml   # launch a sandbox
```

## OpenShell provides the runtime

[OpenShell](https://github.com/NVIDIA/OpenShell) runs AI agents in sandboxed containers with deny-by-default L7 network policy, credential proxy at the network boundary, Landlock filesystem isolation, and inference routing. The harness does not replace any of this.

## The harness adds declarative configuration

- **Guided setup** -- `harness init` generates a config, `harness doctor` validates your environment
- **One-file agent definition** -- agent, providers, gateway, policy, and sandbox files in a single YAML
- **Multi-document YAML** -- `kind: agent/provider/gateway/payload/policy` composed in one file
- **Payload files** -- upload configs to sandbox paths without rebuilding the image
- **Headless task mode** -- `--task "do something"` runs the agent and outputs to stdout
- **Multi-target deploy** -- same YAML works on local Podman, kind, and OpenShell
- **Dry-run validation** -- `--dry-run` checks everything before deploying
- **Config inspection** -- `-o yaml` outputs the fully resolved config

## Use OpenShell directly for runtime operations

```bash
openshell sandbox connect <name>     # interactive shell
openshell sandbox exec <name> -- ... # run commands
openshell sandbox logs <name>        # view logs
openshell policy get <name>          # inspect policy
```

The harness handles setup. OpenShell handles the runtime.

## Install

```bash
# macOS
brew tap nvidia/openshell && brew install openshell && brew services start openshell

# Download the harness binary
curl -L https://github.com/robbycochran/harness-openshell/releases/latest/download/harness_darwin_arm64 -o harness
chmod +x harness
```

Or build from source: `make cli`

## Quick Start

```bash
# 1. Generate a config (picks entrypoint, providers, gateway target)
harness init

# 2. Check your environment
harness doctor

# 3. Launch the sandbox
harness apply -f harness.yaml
```

That's it. `init` asks three questions and writes a `harness.yaml`. `doctor` tells you if anything is missing. `apply` launches the sandbox.

### More examples

```bash
# Run a task headlessly (agent outputs to stdout)
harness apply -f harness.yaml --task "review this codebase for security issues"

# Run a task from a file
harness apply -f harness.yaml --task @tasks/review.md

# Interactive mode
harness apply -f harness.yaml --attach

# Validate without deploying
harness apply -f harness.yaml --dry-run

# See the fully resolved config
harness apply -f harness.yaml -o yaml

# Override the entrypoint
harness apply -f harness.yaml --entrypoint opencode

# Use a profile directly (skip init)
harness apply -f profiles/agent-default.yaml
```

## The Agent YAML

```yaml
# profiles/agent-default.yaml
name: agent
entrypoint: claude
tty: true

providers:
  - profile: github
  - profile: vertex-local
  - profile: atlassian
    env:
      JIRA_URL: ${JIRA_URL}
      JIRA_USERNAME: ${JIRA_USERNAME}
  - profile: gws

env:
  ANTHROPIC_BASE_URL: https://inference.local
  ANTHROPIC_API_KEY: sk-ant-openshell-proxy-managed

payloads:
  - sandbox_path: /sandbox/.claude/CLAUDE.md
    local_path: profiles/images/sandbox-default/CLAUDE.md
  - sandbox_path: /sandbox/.claude.json
    local_path: profiles/images/sandbox-default/claude.json
  - sandbox_path: /sandbox/.mcp.json
    local_path: profiles/images/sandbox-default/mcp.json
```

### Multi-Document Harness YAML

Bundle everything in one file:

```yaml
---
kind: agent
name: my-agent
entrypoint: claude
providers:
  - profile: github
---
kind: provider
name: github
type: github
credentials: [GITHUB_TOKEN]
---
kind: payload
sandbox_path: /sandbox/.claude/CLAUDE.md
content: |
  You are a security review agent.
---
kind: policy
network_policies:
  github:
    endpoints:
      - { host: "api.github.com", port: 443 }
```

```bash
harness apply -f harness.yaml
```

## Targets

```bash
harness apply -f profiles/agent-default.yaml                     # local Podman
harness apply -f profiles/agent-default.yaml --gateway ocp        # deploy to OpenShift
harness apply -f profiles/agent-opencode.yaml                     # OpenCode agent
harness deploy ocp                                                # deploy gateway only
```

## How It Works

```
harness init -----> harness.yaml (your config)
harness doctor ---> validates environment
harness apply ---> openshell CLI --> Gateway (Podman or K8s)
                                      |-- Provider credentials
                                      |-- L7 network policy
                                      |-- inference.local proxy
                                      +-- Sandbox container
                                           |-- claude / opencode
                                           |-- gh, mcp-atlassian, gws
                                           +-- placeholder tokens
```

The harness orchestrates three OpenShell components:

- **Gateway** -- credential proxy and L7 network policy engine. Runs as Podman container (local) or K8s StatefulSet (remote).
- **Providers** -- credential registrations. Provider profiles in `profiles/providers/` are imported to the gateway. Missing credentials are skipped.
- **Sandbox** -- isolated container running the agent entrypoint. Credentials are proxy-managed placeholder tokens. Network egress is deny-by-default at L7.

See the [OpenShell docs](https://github.com/NVIDIA/OpenShell) for the full security model.

## Reference

### Commands

```
harness init [--output FILE] [--force] [--non-interactive]
    Generate a harness.yaml config file.
    Prompts for entrypoint, providers, and gateway target.
    Discovers available providers from openshell.
    --non-interactive writes the embedded default without prompts.
    --force overwrites an existing file.

harness doctor [-f FILE] [-o table|json|yaml]
    Validate that your environment can run the configured sandbox.
    Phase 1 (offline): checks openshell, target deps, provider credentials.
    Phase 2 (online): checks provider registration if gateway is reachable.
    Exit 0 if ready, exit 1 if something is missing.

harness apply -f FILE [--task TEXT|@FILE] [--entrypoint NAME] [--gateway NAME] [--attach] [--dry-run] [-o yaml|json]
    Deploy a sandboxed agent from a config file.
    --task runs the agent headlessly with a task (inline text or @filepath).
    --entrypoint overrides the agent entrypoint (claude, opencode, bash).
    --attach enables interactive TTY mode.
    --dry-run validates without deploying.
    -o yaml outputs the fully resolved config.

harness deploy [local|ocp|kind]
    Deploy or verify the gateway for a target.

harness get agents|providers|gateways [-o table|json|yaml]
    List resources with consistent structured output.

harness describe <name> [-o table|json|yaml]
    Detailed status for a specific sandbox.

harness delete <name> [--all] [--providers] [--k8s]
    Delete sandboxes or other resources.
```

For runtime operations, use openshell directly:
```
openshell sandbox connect [NAME]
openshell sandbox logs [NAME] [--tail]
openshell sandbox exec [NAME] -- ...
```

### Config Files

| File | Purpose |
|------|---------|
| `profiles/agent-*.yaml` | Agent config: image, entrypoint, providers, env, payloads, task |
| `profiles/providers/` | OpenShell provider profiles (imported to gateway on registration) |
| `profiles/gateways/*.yaml` | Gateway profiles: `local.yaml`, `kind.yaml`, `ocp.yaml` |
| `profiles/images/sandbox-default/` | Sandbox image defaults (overridable via payloads) |

### Credentials

Each provider requires credentials on the host. Missing providers are skipped.

| Provider | Required |
|----------|----------|
| `github` | `GITHUB_TOKEN` env var |
| `vertex-local` | `gcloud auth application-default login` + `ANTHROPIC_VERTEX_PROJECT_ID` + `CLOUD_ML_REGION` |
| `atlassian` | `JIRA_API_TOKEN` + `JIRA_URL` + `JIRA_USERNAME` |
| `gws` | `gws auth login` (OAuth via [gws CLI](https://github.com/googleworkspace/cli)) |

## Documentation Map

| Document | What it is |
|----------|------------|
| [SPEC.md](SPEC.md) | Authoritative behavior spec for the CLI |
| [AGENTS.md](AGENTS.md) | Contributor guide: coding principles, upstream conventions, validation |
| [TODO.md](TODO.md) | Roadmap and known gaps |
| [docs/archive/](docs/archive/README.md) | Historical design docs |

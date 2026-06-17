# harness

> **Experimental.** Built on [OpenShell](https://github.com/NVIDIA/OpenShell), which is itself alpha software. Expect breaking changes in both.

One-shot sandboxed agent runs. Point a skill at a repo, get results.

```bash
# Run a C++ review skill against a repo
harness apply -f cpp-review.yaml --task "highest priority remediation"
```

```yaml
# cpp-review.yaml
kind: agent
name: cpp-review
entrypoint: claude
task: @skills/cpp-pro/SKILL.md

providers:
  - profile: github
  - profile: google-vertex-ai

payloads:
  - sandbox_path: /sandbox/.claude/CLAUDE.md
    content: |
      You are a C++ expert. Clone github.com/stackrox/collector
      and apply the cpp-pro skill to identify the highest-priority
      remediation. Focus on modern C++ (17/20), RAII, move semantics,
      and concurrency safety.
```

The harness wires up the sandbox, credentials, and network policy. The agent runs the task and exits.

## Why this exists

[OpenShell](https://github.com/NVIDIA/OpenShell) is a foundation layer -- sandboxed containers with deny-by-default L7 network policy, credential proxy, Landlock filesystem isolation, and inference routing. It is designed as a strict, secure base that other tooling builds workflows on.

The harness is a workflow layer on top. It bridges the gap between "I have a skill and a target repo" and "the agent is running in a sandbox with the right credentials and network access." One YAML file defines the agent, providers, payloads, and policy. One command deploys it.

OpenShell's upstream direction is toward a [Kubernetes Operator](https://github.com/NVIDIA/OpenShell/issues/1719) where providers and sandboxes become CRDs and the gateway narrows to data-plane only. The harness explores what the workflow layer looks like above that -- and covers the local Podman development path that no operator will own.

## Quick Start

```bash
harness init                        # generate a config
harness doctor                      # check your environment
harness apply -f harness.yaml       # launch a sandbox
```

`init` asks three questions and writes a `harness.yaml`. `doctor` validates your environment. `apply` deploys the sandbox.

### One-shot tasks

```bash
# Inline task
harness apply -f harness.yaml --task "review this codebase for security issues"

# Task from a file (skill, playbook, checklist)
harness apply -f harness.yaml --task @skills/cpp-pro/SKILL.md

# Interactive mode
harness apply -f harness.yaml --attach
```

### Multi-target

```bash
harness apply -f harness.yaml                    # local Podman
harness apply -f harness.yaml --gateway ocp      # OpenShift
harness apply -f harness.yaml --gateway kind      # kind cluster
```

Same config, different targets.

## The Agent YAML

A single file defines what runs, what credentials it gets, and what files are uploaded to the sandbox.

```yaml
name: agent
entrypoint: claude
tty: true

providers:
  - profile: github
  - profile: google-vertex-ai
  - profile: atlassian
    env:
      JIRA_URL: ${JIRA_URL}
      JIRA_USERNAME: ${JIRA_USERNAME}

env:
  ANTHROPIC_BASE_URL: https://inference.local

payloads:
  - sandbox_path: /sandbox/.claude/CLAUDE.md
    local_path: profiles/images/sandbox-default/CLAUDE.md
  - sandbox_path: /sandbox/.mcp.json
    local_path: profiles/images/sandbox-default/mcp.json
```

### Multi-document YAML

Bundle agent, providers, payloads, and policy in one file:

```yaml
---
kind: agent
name: cpp-reviewer
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
  You are a C++ security review agent.
---
kind: policy
network_policies:
  github:
    endpoints:
      - { host: "api.github.com", port: 443 }
```

## How It Works

```
harness apply -f config.yaml
    |
    +-> Deploy gateway (Podman container or K8s StatefulSet)
    +-> Register providers (credentials from host env)
    +-> Upload payloads (CLAUDE.md, MCP config, skills)
    +-> Create sandbox (isolated container, deny-by-default network)
    +-> Run task (agent executes, outputs results)
```

OpenShell provides the runtime isolation. The harness provides the workflow.

For runtime operations, use openshell directly:
```bash
openshell sandbox connect <name>     # interactive shell
openshell sandbox exec <name> -- ... # run commands
openshell sandbox logs <name>        # view logs
```

## Install

```bash
# macOS
brew tap nvidia/openshell && brew install openshell && brew services start openshell

# Download the harness binary
curl -L https://github.com/robbycochran/harness-openshell/releases/latest/download/harness_darwin_arm64 -o harness
chmod +x harness
```

Or build from source: `make cli`

## Reference

### Commands

| Command | What it does |
|---------|--------------|
| `harness init` | Generate a harness.yaml (interactive or `--non-interactive`) |
| `harness doctor` | Validate environment (offline + online checks) |
| `harness apply -f FILE` | Deploy a sandbox from config |
| `harness apply --task TEXT` | One-shot headless run |
| `harness apply --task @FILE` | One-shot from a skill/playbook file |
| `harness apply --attach` | Interactive TTY mode |
| `harness apply --dry-run` | Validate without deploying |
| `harness apply -o yaml` | Output resolved config |
| `harness deploy [local\|ocp\|kind]` | Deploy gateway only |
| `harness get agents\|providers\|gateways` | List resources |
| `harness describe <name>` | Sandbox details |
| `harness delete <name> [--all]` | Tear down |

### Credentials

Each provider discovers credentials from the host. Missing providers are skipped.

| Provider | Required |
|----------|----------|
| `github` | `GITHUB_TOKEN` env var |
| `google-vertex-ai` | `gcloud auth application-default login` + `ANTHROPIC_VERTEX_PROJECT_ID` |
| `atlassian` | `JIRA_API_TOKEN` + `JIRA_URL` + `JIRA_USERNAME` |
| `google-workspace` | `gws auth login` ([gws CLI](https://github.com/googleworkspace/cli)) |

### Config Files

| File | Purpose |
|------|---------|
| `profiles/agent-*.yaml` | Agent configs |
| `profiles/providers/` | Provider profiles (imported to gateway) |
| `profiles/gateways/*.yaml` | Gateway profiles per target |
| `profiles/images/sandbox-default/` | Sandbox image defaults (overridable via payloads) |

## Documentation

| Document | What it is |
|----------|------------|
| [SPEC.md](SPEC.md) | Behavior spec for the CLI |
| [AGENTS.md](AGENTS.md) | Contributor guide |
| [TODO.md](TODO.md) | Roadmap and upstream tracking |

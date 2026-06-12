# OpenShell Harness -- Hackathon Demo Script

> **Goal**: Show how OpenShell Harness gives a sandboxed Claude agent local
> access to your real tools (Jira, GitHub, Gmail) through a single
> `harness up --local` command.

---

## Act 1: The Problem (30 seconds)

"AI coding agents can read your code, but they can't see your tickets,
your PRs, or your email. You end up copy-pasting context between tabs.
OpenShell Harness solves this by giving a sandboxed Claude agent
authenticated access to your actual work tools -- Jira, GitHub, Google
Workspace -- through a local gateway that manages credentials so the
agent never sees your secrets."

---

## Act 2: The Config (1 minute)

### Show the demo agent config

```bash
cat agents/demo.yaml
```

**Talk through it:**

- `image:` -- the sandbox container image (has Claude CLI baked in)
- `entrypoint: claude` -- Claude Code runs inside the sandbox
- `task: demo/DEMO-TASK.md` -- the prompt file; rendered into the payload
  and passed to Claude automatically on start. "One config, one command,
  the agent knows what to do."
- `tty: false` -- non-interactive; output streams to your terminal
- `providers:` -- which tool integrations the agent gets:
  - `github` -- read-only GitHub API + git
  - `vertex-local` -- Vertex AI inference (no API key leaves your machine)
  - `atlassian` -- Jira/Confluence via Basic auth resolved by the gateway proxy
  - `gws` -- Google Workspace (Gmail, Calendar, Docs) via gateway-managed OAuth
- `env:` -- sandbox env vars; note `ANTHROPIC_BASE_URL: https://inference.local`
  routes all inference through the gateway proxy (cost tracking, audit log)

### Show the provider definitions

```bash
ls agents/providers/profiles/
```

**Talk through it:**

- Each provider declares its `inputs` -- env vars, files, or health checks
- The harness validates all inputs before deploying
- Secrets (`secret = true`) are mounted into the sandbox as K8s secrets or
  podman secrets -- the agent binary never reads them directly

### Show the gateway config

```bash
cat gateways/local/gateway.yaml
```

**Talk through it:**

- `type = "local"` -- runs on your laptop via podman/docker
- `providers.enabled` -- which built-in providers are active
- `providers.custom` -- GWS is a custom provider (gateway-managed OAuth refresh)

---

## Act 3: Launch It (30 seconds)

```bash
# Build the CLI (if not already built)
make cli

# Deploy gateway + register providers + create sandbox with the demo task
./harness up --local --agent demo
```

**While it starts:** "The harness is doing three things: starting the gateway
container, registering each provider's credentials with the gateway, and
creating a sandbox container with Claude inside. The `--agent demo` flag
tells it to use `agents/demo.yaml`, which has a task baked in -- the agent
starts working immediately. The gateway acts as a proxy -- all API calls from
the sandbox go through it, so credentials never leave the gateway process."

---

## Act 4: Watch It Work (2 minutes)

Claude starts automatically with the task from `demo/DEMO-TASK.md`. No paste
needed -- the task was rendered into the sandbox payload at launch time.

The agent will:
1. Query Jira for your assigned tickets (via the Atlassian provider)
2. Query GitHub for recent PRs on stackrox/skills (via the GitHub provider)
3. Search Gmail for the latest memolist thread (via the GWS provider)
4. Format everything as markdown tables

**While Claude works:** "Notice Claude is hitting real APIs -- Jira, GitHub,
Gmail -- all through the gateway. No API keys in the sandbox. If I revoke a
provider, the agent loses access instantly without rebuilding the container."

> **Fallback:** If `--agent` isn't wired yet, run `./harness up --local`
> and paste the contents of `demo/DEMO-TASK.md` into the Claude prompt.

---

## Act 5: Teardown (15 seconds)

```bash
# Tear down sandbox + gateway
./harness teardown
```

"One command cleans up everything. The sandbox is ephemeral -- no state
persists between sessions unless you explicitly save it."

---

## Talking Points for Q&A

- **Security model**: The agent runs in a sandboxed container with no host
  filesystem access. Credentials live in the gateway, not the sandbox.
  The gateway proxy means the agent can't exfiltrate tokens even if
  prompt-injected.

- **Provider extensibility**: Adding a new tool = adding a TOML block to
  a provider profile in `agents/providers/profiles/` and an entry in
  `agents/default.yaml`. No code changes.

- **Local vs Remote**: Same config works with `harness up --remote` for
  OCP/K8s deployment. The gateway runs as a sidecar pod, providers mount
  as K8s secrets.

- **Cost control**: All inference routes through the gateway proxy, which
  can enforce cost limits, log token usage, and rate-limit per-agent.

- **Why not just MCP?**: MCP gives the agent tool access, but OpenShell
  gives it *authenticated, sandboxed, auditable* tool access with
  credential isolation. MCP servers inside the sandbox talk through the
  gateway -- the agent code is identical either way.

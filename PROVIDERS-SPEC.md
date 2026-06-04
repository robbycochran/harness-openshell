# Configuration Spec

Three config files drive the harness:

- **`providers.toml`** — provider definitions (inputs, types, checks)
- **`openshell.toml`** — which providers to enable, inference model
- **`agents/*.toml`** — per-agent sandbox config (image, command, env vars)

## providers.toml

### Provider entry

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique identifier |
| `type` | yes | `"openshell"` (registered with gateway) or `"custom"` (harness workaround) |
| `description` | yes | Shown in preflight output |
| `required` | no | If `true`, preflight `--strict` fails when inputs missing |
| `method` | no | Registration method (e.g., `"from-gcloud-adc"`) |
| `upstream` | no | Link to upstream issue (custom providers only) |

### Input entry

Inline tables in the `inputs` array:

| Field | Required | Description |
|-------|----------|-------------|
| `key` | yes | Env var name, file path, or shell command |
| `kind` | yes | `"env"`, `"file"`, or `"check"` |
| `secret` | no | Mask value in preflight output. Default: `false` |

### Input kinds

- **`env`** — checks if env var is set. Shows `✓ local env: VAR=value` or masked if secret.
- **`file`** — checks file exists. Extracts metadata from known formats (ADC project, GWS client_id).
- **`check`** — runs shell command. Shows `✓ check: command` or `✗ check: command`.

### Example

```toml
[[providers]]
name = "github"
type = "openshell"
description = "GitHub API and git operations"
required = true
inputs = [
  { key = "GITHUB_TOKEN", kind = "env", secret = true },
]

[[providers]]
name = "atlassian"
type = "openshell"
description = "Jira and Confluence"
inputs = [
  { key = "JIRA_API_TOKEN", kind = "env", secret = true },
  { key = "JIRA_URL", kind = "env" },
  { key = "JIRA_USERNAME", kind = "env" },
  { key = "curl -sf ${JIRA_URL}/rest/api/2/serverInfo -o /dev/null", kind = "check" },
]
```

## openshell.toml

```toml
providers = ["github", "vertex-local", "atlassian"]
providers-custom = ["gws"]

[inference]
model = "claude-sonnet-4-6"
```

If absent, all providers are enabled.

## agents/*.toml

Per-agent sandbox configuration. `sandbox-podman.sh` and `sandbox-ocp.sh` read these.

```toml
name = "agent"
image = "quay.io/rcochran/openshell:sandbox"
command = "claude --bare"
keep = true
providers = ["github", "vertex-local", "atlassian"]

[env]
ANTHROPIC_BASE_URL = "https://inference.local"
ANTHROPIC_API_KEY = "sk-ant-openshell-proxy-managed"
JIRA_URL = "https://mysite.atlassian.net"
JIRA_USERNAME = "user@example.com"
```

The `[env]` section is uploaded as `sandbox.env` and sourced inside the sandbox.

## Preflight

`openshell-harness-preflight.sh` reads `providers.toml` + `openshell.toml` and checks:

1. OpenShell CLI installed
2. Gateway reachable (podman or k8s, based on active gateway)
3. Each enabled provider's inputs (env vars, files, commands)
4. Reports `✓`/`✗` per input with `local env:`, `local file:`, `check:` prefixes
5. With `--strict`, exits non-zero if any required provider has missing inputs

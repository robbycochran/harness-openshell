# Sandbox Harness Operations

Tracks credentials, MCP servers, network policy, and the sandbox startup flow.

## Base Image Assumptions

The harness expects the base image to provide:
- `claude` CLI (Claude Code)
- `node` / `npm`
- `python3` / `pip` / `uv`
- `gh` CLI
- `git`, `curl`

The default base image (`ghcr.io/nvidia/openshell-community/sandboxes/base:latest`) satisfies all of these.

## Credentials

Credentials are managed by the **OpenShell provider system**. They are stored in the gateway database and injected as environment variables into sandbox pods automatically.

### Provider-managed credentials

| Provider | Type | Env Vars | Purpose |
|----------|------|----------|---------|
| `github` | github | `GITHUB_TOKEN` | `gh` CLI auth |
| `atlassian` | generic | `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | mcp-atlassian MCP server |
| `anthropic` | anthropic | `ANTHROPIC_API_KEY` | Direct Anthropic API (optional) |

Register via `setup-providers.sh` or manually:
```shell
openshell provider create --name github --type github --credential GITHUB_TOKEN="$GITHUB_TOKEN"
```

### File-based credentials (uploaded at sandbox creation)

| File | Upload Path | Purpose |
|------|-------------|---------|
| GCP ADC (`application_default_credentials.json`) | `/tmp/adc.json` | Vertex AI auth |
| GWS config directory | `/tmp/gws-config/` | Google Workspace CLI |

These are uploaded via `--upload` flags in `ocp-sandbox.sh`.

### How to rotate

```shell
# Provider credentials — update in-place
openshell provider update github --credential GITHUB_TOKEN="ghp_new_token"
openshell provider update atlassian \
  --credential JIRA_API_TOKEN="new_token"

# GCP ADC — re-authenticate and launch a new sandbox
gcloud auth application-default login

# GWS OAuth — re-authenticate locally
gws auth login
# New sandboxes will pick up the updated files from $GWS_CONFIG_DIR
```

### How to revoke

- **GCP ADC**: `gcloud auth application-default revoke`
- **Atlassian API token**: https://id.atlassian.com/manage-profile/security/api-tokens
- **GitHub PAT**: https://github.com/settings/tokens
- **GWS OAuth**: https://myaccount.google.com/permissions

## Environment Variables

### Vertex AI (Claude Code)
```shell
GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json
CLAUDE_CODE_USE_VERTEX=1
CLOUD_ML_REGION=global
ANTHROPIC_VERTEX_PROJECT_ID=<project-id>
GOOGLE_CLOUD_LOCATION=<region>
GOOGLE_CLOUD_PROJECT=<project-id>
```

Set via `VERTEX_PROJECT` and `VERTEX_REGION` environment variables before running `ocp-sandbox.sh`.

## MCP Servers

Installed at sandbox startup via `pip`. Configured via Claude Code's config file.

### mcp-atlassian
- **Source**: https://github.com/sooperset/mcp-atlassian
- **Install**: `pip install mcp-atlassian`
- **Config**: Written to `~/.claude.json` at startup
- **Env vars**: Injected by the `atlassian` provider

### gws (Google Workspace CLI)
- **Source**: https://github.com/googleworkspace/cli
- **Install**: Downloaded from GitHub releases
- **Config**: `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config`
- **Auth**: Uses pre-authenticated OAuth credentials uploaded from local machine

## Network Policy

File: `vertex-policy.yaml`

| Pattern | Purpose |
|---------|---------|
| `*.googleapis.com:443` | Vertex AI, GCP auth |
| `*.google.com:443` | Google OAuth |
| `*.anthropic.com:443` | Claude telemetry |
| `github.com:443`, `*.github.com:443` | GitHub API, repos |
| `*.atlassian.net:443`, `*.atl-paas.net:443` | Jira/Confluence |
| `registry.npmjs.org:443` | npm packages |
| `pypi.org:443`, `*.pythonhosted.org:443` | Python packages |

## Custom Image Strategy

The harness separates cleanly into image and configuration layers:

- **Image layer**: Base OS, runtimes, CLI tools
- **Harness layer**: Providers, MCP servers, env vars, network policy

To use a different base image:
1. Build an image with the required tools
2. Set `SANDBOX_IMAGE` before running `deploy.sh`, or use `--from <image>` on sandbox create
3. The harness scripts work unchanged

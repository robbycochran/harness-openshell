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

### Provider-managed credentials (Bearer auth)

Provider credentials are injected as placeholder env vars. The sandbox proxy
resolves them transparently in HTTP `Authorization: Bearer` headers.

| Provider | Type | Env Vars | Purpose |
|----------|------|----------|---------|
| `github` | github | `GITHUB_TOKEN` | `gh` CLI auth |
| `anthropic` | anthropic | `ANTHROPIC_API_KEY` | Direct Anthropic API (optional) |

Register via `setup-providers.sh` or manually:
```shell
openshell provider create --name github --type github --credential GITHUB_TOKEN="$GITHUB_TOKEN"
```

### Direct env vars (Basic auth)

Atlassian credentials use Basic auth (`base64(username:token)`), which hides
placeholders from the proxy resolver. These are passed as literal env vars
by `ocp-sandbox.sh` from the host environment.

| Env Var | Purpose |
|---------|---------|
| `JIRA_URL` | Atlassian site URL |
| `JIRA_USERNAME` | Atlassian email |
| `JIRA_API_TOKEN` | Atlassian API token |

### Decomposed file credentials (provider-managed)

GCP ADC credentials are decomposed into individual provider fields so secrets
never exist as plaintext files in the sandbox. All 7 ADC fields are stored as
provider credentials by `setup-providers.sh` (requires `jq`).

| Provider | Credentials | Source |
|----------|------------|--------|
| `gcp-adc` | `ADC_CLIENT_ID`, `ADC_CLIENT_SECRET`, `ADC_REFRESH_TOKEN`, `ADC_ACCOUNT`, `ADC_QUOTA_PROJECT_ID`, `ADC_TYPE`, `ADC_UNIVERSE_DOMAIN` | `application_default_credentials.json` |

The ADC file (`/tmp/adc.json`) is reconstructed inside the sandbox from these
env vars. Secret fields contain placeholder tokens; when Google's OAuth library
sends a token exchange POST to `oauth2.googleapis.com`, the proxy resolves
them via L7 `request_body_credential_rewrite`.

### File-based credentials (uploaded at sandbox creation)

| File | Upload Path | Purpose |
|------|-------------|---------|
| GWS config directory | `/tmp/gws-config/` | Google Workspace CLI |

GWS credentials are encrypted by the `gws` CLI and cannot be decomposed into
individual fields. They are uploaded via `--upload` in `ocp-sandbox.sh`.
When OpenShell adds file-based credential projection (issues #1268, #1423),
GWS files can move to the provider system.

### How to rotate

```shell
# Provider credentials — update in-place
openshell provider update github --credential GITHUB_TOKEN="ghp_new_token"

# Atlassian — update env vars and launch a new sandbox
export JIRA_API_TOKEN="new_token"

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

### L7 Configuration

The `google_apis` policy has L7 `request_body_credential_rewrite` enabled.
This is required because GCP OAuth token exchange sends `client_secret` and
`refresh_token` as form-encoded POST body parameters to `oauth2.googleapis.com`.
Without L7 body rewrite, the proxy can't resolve placeholder tokens in POST
bodies — only in headers and URL paths.

## Custom Image Strategy

The harness separates cleanly into image and configuration layers:

- **Image layer**: Base OS, runtimes, CLI tools
- **Harness layer**: Providers, MCP servers, env vars, network policy

To use a different base image:
1. Build an image with the required tools
2. Set `SANDBOX_IMAGE` before running `deploy.sh`, or use `--from <image>` on sandbox create
3. The harness scripts work unchanged

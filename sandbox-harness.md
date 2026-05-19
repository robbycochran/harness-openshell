# Sandbox Harness Setup

Tracks everything needed to configure a Claude Code sandbox session on top of any base image. These steps are image-agnostic — they handle credentials, MCP servers, CLI tools, and network policy.

## Base Image Assumptions

The harness expects the base image to provide:
- `claude` CLI (Claude Code)
- `node` / `npm`
- `python3` / `pip` / `uv`
- `gh` CLI
- `git`, `curl`

The current base image (`ghcr.io/nvidia/openshell-community/sandboxes/base:latest`) satisfies all of these.

## Credentials (K8s Secrets)

All credentials are stored as K8s secrets in the `openshell` namespace and uploaded into sandboxes at creation time. They are never baked into images.

| Secret | Contents | Mount Path | Purpose |
|--------|----------|------------|---------|
| `gcp-adc` | `adc.json` — Google ADC (authorized_user refresh token) | `/tmp/adc.json` | Vertex AI auth for Claude Code |
| `atlassian-creds` | `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` | env vars | mcp-atlassian MCP server |
| `github-token` | `GITHUB_TOKEN` | env var | `gh` CLI auth |
| `gws-credentials` | `client_secret.json`, `credentials.enc`, `.encryption_key`, `token_cache.json` | `/tmp/gws-config/` | Google Workspace CLI (`gws`) |

### How to revoke

- **GCP ADC**: `gcloud auth application-default revoke` (invalidates the refresh token everywhere)
- **Atlassian API token**: Revoke at https://id.atlassian.com/manage-profile/security/api-tokens
- **GitHub PAT**: Revoke at https://github.com/settings/tokens
- **GWS OAuth**: Revoke at https://myaccount.google.com/permissions (find the OAuth app and remove access)

### How to rotate

```shell
export KUBECONFIG=$PWD/kubeconfig

# GCP ADC
gcloud auth application-default login
kubectl delete secret gcp-adc -n openshell
kubectl create secret generic gcp-adc -n openshell \
  --from-file=adc.json=$HOME/.config/gcloud/application_default_credentials.json

# Atlassian
kubectl delete secret atlassian-creds -n openshell
kubectl create secret generic atlassian-creds -n openshell \
  --from-literal=JIRA_URL=https://redhat.atlassian.net \
  --from-literal=JIRA_USERNAME=<email> \
  --from-literal=JIRA_API_TOKEN=<new-token>

# GitHub
kubectl delete secret github-token -n openshell
kubectl create secret generic github-token -n openshell \
  --from-literal=GITHUB_TOKEN=<new-pat>

# GWS (re-auth locally first: gws auth login)
kubectl delete secret gws-credentials -n openshell
kubectl create secret generic gws-credentials -n openshell \
  --from-file=client_secret.json=$HOME/.config/gws/client_secret.json \
  --from-file=credentials.enc=$HOME/.config/gws/credentials.enc \
  --from-file=encryption_key=$HOME/.config/gws/.encryption_key \
  --from-file=token_cache.json=$HOME/.config/gws/token_cache.json
```

## Environment Variables

Set directly in the sandbox command (not via the provider system, which wraps values in proxy placeholders).

### Vertex AI (Claude Code)
```shell
GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json
CLAUDE_CODE_USE_VERTEX=1
CLOUD_ML_REGION=global
ANTHROPIC_VERTEX_PROJECT_ID=itpc-gcp-hcm-pe-eng-claude
GOOGLE_CLOUD_LOCATION=us-east5
GOOGLE_CLOUD_PROJECT=itpc-gcp-hcm-pe-eng-claude
```

### Atlassian (mcp-atlassian)
```shell
JIRA_URL=https://redhat.atlassian.net
JIRA_USERNAME=<email>
JIRA_API_TOKEN=<token>
```

### GitHub (gh CLI)
```shell
GITHUB_TOKEN=<pat>
```

## MCP Servers

Installed at sandbox startup via `uv`. Configured via Claude Code's settings file.

### mcp-atlassian
- **Source**: https://github.com/sooperset/mcp-atlassian
- **Install**: `uv pip install mcp-atlassian`
- **Config**: Written to `~/.claude/settings.json` at startup
- **Env vars**: `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`

### gws (Google Workspace CLI)
- **Source**: https://github.com/googleworkspace/cli
- **Install**: `npm install -g @googleworkspace/cli`
- **Config**: `GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config` (files uploaded from K8s secret)
- **Auth**: Uses pre-authenticated OAuth credentials (encrypted at rest in the secret)
- **Capabilities**: Gmail, Calendar, Drive, Docs, Sheets, Chat, Admin — 100+ API methods

### Future MCP servers
Add entries here as we add more. The pattern is:
1. Add the package to the startup install command
2. Add the MCP server config to the settings.json template
3. Add required env vars to the credentials section
4. Add required network endpoints to the policy

## Network Policy

File: `architecture/plans/vertex-policy.yaml`

Current allowed endpoints:

| Pattern | Purpose |
|---------|---------|
| `*.googleapis.com:443` | Vertex AI, GCP auth |
| `*.google.com:443` | Google OAuth |
| `*.anthropic.com:443` | Claude telemetry (statsig) |
| `github.com:443`, `*.github.com:443`, `*.githubusercontent.com:443` | GitHub API, repos |
| `registry.npmjs.org:443` | npm packages |
| `pypi.org:443`, `*.pythonhosted.org:443` | Python packages |
| `*.atlassian.net:443` | Jira/Confluence |
| `*.atl-paas.net:443` | Atlassian CDN/auth |

## Startup Script

The sandbox startup script (`ocp-sandbox.sh`) does:
1. Ensures port-forward is running
2. Ensures gateway config exists
3. Uploads ADC file
4. Sets all env vars
5. Installs MCP servers via `uv`
6. Writes Claude Code MCP config
7. Launches Claude Code (or shell)

## Custom Image Strategy (Future)

When building platform-specific images, the harness separates cleanly:

- **Image layer**: Base OS, runtimes (node, python, rust), CLI tools (gh, git, claude)
- **Harness layer** (this doc): Credentials, MCP servers, env vars, network policy

The harness works on any image that meets the base assumptions above. To support a different platform:
1. Build an image with the required tools
2. Push to quay.io with a new tag (e.g., `scratch:openshell-sandbox-rust`)
3. Use `--from <image>` or update `server.sandboxImage` in the Helm values
4. The harness script works unchanged

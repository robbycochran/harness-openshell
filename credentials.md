# Credential Flows

How credentials are configured, stored, and consumed in sandboxes.

## Mechanisms

OpenShell supports two credential delivery mechanisms. Which one applies
depends on whether the consuming tool sends the credential over HTTP
(where the proxy can intercept it) or reads it locally.

### Provider credentials (proxy-resolved)

Credentials registered with `openshell provider create` are stored in the
gateway database and injected into sandbox pods as **placeholder** environment
variables (e.g., `openshell:resolve:env:v2_GITHUB_TOKEN`). The real value
never enters the sandbox.

When the sandbox makes an HTTP request, the network proxy inspects headers
and (with L7 enabled) request bodies, replacing placeholders with real values
on the wire. The sandbox process only ever sees the placeholder string.

This works for:
- **Bearer auth** — placeholder appears directly in `Authorization: Bearer <placeholder>`
- **POST body params** — placeholder appears in form-encoded fields (requires `request_body_credential_rewrite: true` on the endpoint)

### Literal env vars (direct injection)

Some tools use auth schemes that transform credentials before sending them,
making placeholders unrecognizable to the proxy. These credentials must be
passed as real values.

`ocp-sandbox.sh` base64-encodes values on the host and decodes them inside
the sandbox to survive multi-layer shell expansion without injection risk.

### File upload

Credentials stored as encrypted files that are read locally (not sent over
HTTP) can't use placeholders at all. These are uploaded at sandbox creation
via `--upload` and copied into place during setup.

## Credentials

### GitHub (`github` provider)

| | |
|---|---|
| **Source** | `GITHUB_TOKEN` env var on host |
| **Registration** | `setup-providers.sh` → `openshell provider create --name github --type github` |
| **Sandbox delivery** | Provider placeholder in env |
| **Consumption** | `gh` CLI sends `Authorization: Bearer <placeholder>` → proxy resolves |

### GCP ADC (`gcp-adc` provider)

Google's OAuth client library reads an Application Default Credentials file
and POSTs `client_secret` and `refresh_token` to `oauth2.googleapis.com`
as form-encoded body parameters during token exchange.

| | |
|---|---|
| **Source** | `~/.config/gcloud/application_default_credentials.json` (or `$GOOGLE_APPLICATION_CREDENTIALS`) |
| **Registration** | `setup-providers.sh` extracts all 7 fields via `jq` → `openshell provider create --name gcp-adc --type generic` |
| **Sandbox delivery** | All fields injected as provider placeholder env vars |
| **Reconstruction** | Sandbox startup writes `/tmp/adc.json` from env vars — secret fields contain placeholders |
| **Consumption** | Google OAuth library POSTs secrets to `oauth2.googleapis.com` → proxy resolves via L7 `request_body_credential_rewrite` |

**Provider credentials:**

| Key | Secret? | Purpose |
|-----|---------|---------|
| `ADC_CLIENT_ID` | No | OAuth client identifier |
| `ADC_CLIENT_SECRET` | Yes | OAuth client secret |
| `ADC_REFRESH_TOKEN` | Yes | OAuth refresh token |
| `ADC_ACCOUNT` | No | GCP account email (may be empty) |
| `ADC_QUOTA_PROJECT_ID` | No | Billing/quota project |
| `ADC_TYPE` | No | Credential type (usually `authorized_user`) |
| `ADC_UNIVERSE_DOMAIN` | No | API universe (usually `googleapis.com`) |

**Required env vars at launch:**

| Var | Purpose |
|-----|---------|
| `VERTEX_PROJECT` | GCP project ID for Vertex AI |
| `VERTEX_REGION` | GCP region (optional, defaults to `global` via `CLOUD_ML_REGION`) |

**L7 policy requirement:** The `google_apis` network policy must have
`request_body_credential_rewrite: true` on `*.googleapis.com` and
`*.google.com` endpoints. Without this, the proxy can't resolve placeholders
in POST bodies — only in headers.

### Anthropic (`anthropic` provider)

| | |
|---|---|
| **Source** | `ANTHROPIC_API_KEY` env var on host |
| **Registration** | `setup-providers.sh` → `openshell provider create --name anthropic --type anthropic` |
| **Sandbox delivery** | Provider placeholder in env |
| **Consumption** | Claude SDK sends `x-api-key: <placeholder>` → proxy resolves |

Not needed when using the Vertex AI path (`CLAUDE_CODE_USE_VERTEX=1`).

### Atlassian (literal env vars)

Atlassian credentials use **Basic auth**: `Authorization: Basic base64("username:token")`.
This is incompatible with provider placeholders because:

1. The placeholder string (e.g., `openshell:resolve:env:v2_JIRA_API_TOKEN`)
   would be concatenated with the username and base64-encoded
2. The resulting base64 string is opaque — the proxy can't pattern-match
   the placeholder inside it
3. The proxy only recognizes raw placeholder strings, not encoded ones

So these credentials are passed as **literal values** via `ocp-sandbox.sh`.

| | |
|---|---|
| **Source** | `JIRA_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN` env vars on host |
| **Registration** | None — not provider-managed |
| **Sandbox delivery** | Base64-encoded in sandbox env file, decoded at shell init |
| **Consumption** | mcp-atlassian reads env vars, constructs Basic auth header, sends to `*.atlassian.net` |

**Why base64 for transport?** The values pass through multiple shell expansion
stages: host-side double-quote interpolation into `ocp-sandbox.sh`, then
sandbox-side `source` of `.openshell-env`. Special characters (`'`, `"`,
`` ` ``, `$`, `\n`) in credential values could break quoting or enable
injection. Base64 encoding produces a safe ASCII string that survives all
expansion stages, then is decoded to the original value inside the sandbox.

**Future: OAuth 2.0 3LO.** mcp-atlassian supports OAuth 2.0 with
`ATLASSIAN_OAUTH_CLIENT_SECRET`, `ATLASSIAN_OAUTH_CLOUD_ID`, etc. This uses
Bearer auth for API calls and POSTs `client_secret` during token refresh —
both compatible with provider placeholders (with L7 body rewrite on
`*.atlassian.com`). The `offline_access` scope enables automatic token
refresh inside mcp-atlassian. This would eliminate literal env vars entirely.

Requires: Atlassian site admin approval of an OAuth 2.0 (3LO) app via
https://developer.atlassian.com/console/myapps/. Setup wizard:
`uvx mcp-atlassian --oauth-setup -v`.

**If all three vars are unset**, mcp-atlassian is not configured and the
Atlassian MCP server is skipped.

### Google Workspace (file upload)

GWS credentials are encrypted by the `gws` CLI using its own encryption
scheme. The files are consumed locally by the `gws` binary — no HTTP
request carries the credential, so provider placeholders can't help.

| | |
|---|---|
| **Source** | `$GWS_CONFIG_DIR` (default: `~/.config/gws/`) |
| **Registration** | None — file upload only |
| **Sandbox delivery** | Uploaded via `--upload` at sandbox creation, copied to `/tmp/gws-config/` |
| **Consumption** | `gws` CLI reads files directly from `$GOOGLE_WORKSPACE_CLI_CONFIG_DIR` |

**Files:**

| File | Purpose |
|------|---------|
| `client_secret.json` | OAuth client configuration |
| `credentials.enc` | Encrypted OAuth credentials |
| `token_cache.json` | Cached access/refresh tokens |
| `.encryption_key` | Encryption key for credentials.enc |

When OpenShell adds file-based credential projection (issues #1268, #1423),
GWS files can move to the provider system.

## Network Policy

The sandbox network proxy enforces egress policy per `vertex-policy.yaml`.

| Endpoint Pattern | L7 Body Rewrite | Purpose |
|-----------------|-----------------|---------|
| `*.googleapis.com:443` | Yes | Vertex AI, GCP OAuth token exchange |
| `*.google.com:443` | Yes | Google OAuth |
| `*.anthropic.com:443` | No | Claude telemetry |
| `github.com:443`, `*.github.com:443` | No | GitHub API |
| `*.atlassian.net:443`, `*.atl-paas.net:443` | No | Jira/Confluence |
| `registry.npmjs.org:443` | No | npm packages |
| `pypi.org:443`, `*.pythonhosted.org:443` | No | Python packages |

## Rotation

```shell
# Provider credentials — update in-place, new sandboxes pick up changes
openshell provider update github --credential GITHUB_TOKEN="ghp_new_token"

# GCP ADC — re-authenticate, then re-run setup
gcloud auth application-default login
./setup-providers.sh

# Atlassian — set env vars, launch new sandbox
export JIRA_API_TOKEN="new_token"

# GWS — re-authenticate locally, new sandboxes upload fresh files
gws auth login
```

## Revocation

| Credential | Revoke at |
|------------|-----------|
| GCP ADC | `gcloud auth application-default revoke` |
| Atlassian API token | https://id.atlassian.com/manage-profile/security/api-tokens |
| GitHub PAT | https://github.com/settings/tokens |
| GWS OAuth | https://myaccount.google.com/permissions |

# Sandbox Agent Instructions

You are running inside an OpenShell sandbox on an OpenShift cluster. You have access to the following tools and services.

## Tools Available

### GitHub — `gh` CLI
- Pre-authenticated. Use `gh` for all GitHub operations.
- Examples: `gh repo clone`, `gh pr create`, `gh issue list`, `gh api`
- Do NOT use raw git credential helpers or GITHUB_TOKEN directly in commands.

### Jira & Confluence — mcp-atlassian MCP server
- Connected to `redhat.atlassian.net` via the `atlassian` MCP server.
- Use MCP tools for Jira searches, issue creation, comments, and Confluence page reads.
- Project keys: Use JQL for searching (e.g., `project = ROX AND ...`).

### Google Workspace — `gws` CLI
- Pre-authenticated for Gmail, Calendar, Drive, Docs, Sheets.
- Path: `/sandbox/.local/bin/gws`
- Examples:
  - `gws gmail users messages list --params '{"userId": "me", "maxResults": 5}'`
  - `gws calendar events list --params '{"calendarId": "primary", "maxResults": 5}'`
  - `gws drive files list --params '{"pageSize": 10}'`
  - `gws docs documents get --params '{"documentId": "DOC_ID"}'`
- Use `gws schema <service.resource.method>` to discover API parameters.

### Kubernetes — `kubectl`
- A deploy kubeconfig may be available at `/tmp/deploy-kubeconfig` for deploying to test namespaces.
- Do NOT modify the `openshell` or `agent-sandbox-system` namespaces.

### General Tools
- `python3`, `pip`, `uv` — Python 3.13 with a virtualenv at `/sandbox/.venv`
- `node`, `npm` — Node.js 22
- `git` — pre-installed
- `curl` — pre-installed
- `cargo` — NOT available (no Rust toolchain in sandbox)

## Claude Code Configuration
- Running via **Vertex AI** (Google Cloud), not direct Anthropic API.
- Model selection: Use `--model` flag if the default model isn't available.

## Conventions
- Working directory: `/sandbox`
- Writable paths: `/sandbox`, `/tmp`
- Network: Outbound allowed to Google APIs, GitHub, Atlassian, npm/pypi.
- All credentials are injected at startup and cleaned up on sandbox exit.

#!/usr/bin/env bash
# Runtime setup for the sandbox. Runs once at sandbox creation.
set -euo pipefail

# ── Source env vars from agent config ─────────────────────────────────
OPENSHELL_DIR="/sandbox/.config/openshell"
if [[ -f "$OPENSHELL_DIR/sandbox.env" ]]; then
  . "$OPENSHELL_DIR/sandbox.env"
  cat "$OPENSHELL_DIR/sandbox.env" >> /sandbox/.bashrc
fi

# ── Git auth ──────────────────────────────────────────────────────────
gh auth setup-git 2>/dev/null || true

# ── Append provider-specific docs to CLAUDE.md ────────────────────────
CLAUDE_MD="/sandbox/.claude/CLAUDE.md"

if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  cat >> "$CLAUDE_MD" <<'DOCS'

## GitHub — `gh` CLI
- Pre-authenticated. Use `gh` for all GitHub operations.
- Examples: `gh repo clone`, `gh pr create`, `gh issue list`, `gh api`
DOCS
fi

if [[ -n "${JIRA_URL:-}" ]]; then
  cat >> "$CLAUDE_MD" <<'DOCS'

## Jira & Confluence — mcp-atlassian MCP server
- Connected via the `atlassian` MCP server (credentials injected by provider).
- Use MCP tools for Jira searches, issue creation, comments, and Confluence page reads.
DOCS
fi

if [[ -n "${GOOGLE_WORKSPACE_CLI_TOKEN:-}" ]]; then
  cat >> "$CLAUDE_MD" <<'DOCS'

## Google Workspace — `gws` CLI
- Pre-authenticated for Gmail, Calendar, Drive, Docs, Sheets.
- Use `gws schema <service.resource.method>` to discover API parameters.
- Examples:
  - `gws gmail users messages list --params '{"userId": "me", "maxResults": 5}'`
  - `gws calendar events list --params '{"calendarId": "primary", "maxResults": 5}'`
  - `gws drive files list --params '{"pageSize": 10}'`
DOCS
fi

echo "Setup complete."

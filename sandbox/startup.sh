#!/usr/bin/env bash
# Runtime environment setup for the sandbox.
#
# Runs once at sandbox creation (sourced, not subshell). Configures
# environment, installs skills/plugins, and sets up MCP servers. Writes
# .openshell-env so reconnects pick up the same environment.
#
# ── What the provider system handles (no work needed here) ─────────────
#
#   GITHUB_TOKEN           → github provider, Bearer auth
#   GOOGLE_VERTEX_AI_TOKEN → vertex-local provider, gateway-minted OAuth token
#   JIRA_API_TOKEN         → atlassian provider, Basic auth (proxy decodes
#                            base64, resolves placeholder, re-encodes)
#
# Inference routing: Claude Code sends requests to https://inference.local.
# The gateway proxies to Vertex AI using the vertex-local provider credentials.
# No Anthropic API key is needed — ANTHROPIC_API_KEY is a dummy value.
#
set -euo pipefail

# ── Ensure GWS config dir exists ───────────────────────────────────────
mkdir -p /tmp/gws-config
chmod 700 /tmp/gws-config

# ── Environment file (persists across reconnects) ──────────────────────
cat > /sandbox/.openshell-env <<'ENVEOF'
export ANTHROPIC_BASE_URL=https://inference.local
export ANTHROPIC_API_KEY=sk-ant-openshell-proxy-managed
export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
export CLAUDE_CODE_SANDBOXED=1
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR=/tmp/gws-config
export GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=/tmp/gws-config/credentials.json
export CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=1
export PATH="/sandbox/.local/bin:$PATH"
ENVEOF

grep -q openshell-env /sandbox/.bashrc 2>/dev/null || {
  echo ". ~/.openshell-env 2>/dev/null" >> /sandbox/.bashrc
}
. /sandbox/.openshell-env

# ── Configure git auth via gh credential helper ───────────────────────
# Allows git clone of private repos — the gh credential helper sends
# GITHUB_TOKEN (provider placeholder) which the proxy resolves.
gh auth setup-git 2>/dev/null || true

# ── Copy GWS credentials if uploaded ──────────────────────────────────
if [[ -d /sandbox/.harness/creds/gws-config ]]; then
  cp /sandbox/.harness/creds/gws-config/* /tmp/gws-config/ 2>/dev/null || true
  chmod 600 /tmp/gws-config/* 2>/dev/null || true
fi

# ── Install skills/plugins ────────────────────────────────────────────
# Reads SANDBOX_SKILLS_JSON env var (set by the launcher from config.yaml).
# Auto-detects format:
#   - If repo has .claude-plugin/ → claude plugin marketplace add
#   - Otherwise → scan for SKILL.md dirs and copy to skill discovery paths
if [[ -n "${SANDBOX_SKILLS_JSON:-}" ]]; then
  python3 << 'PYEOF'
import json, os, shutil, subprocess, sys

skills = json.loads(os.environ.get("SANDBOX_SKILLS_JSON", "[]"))
if not skills:
    sys.exit(0)

agents_dir = "/sandbox/.agents/skills"
claude_dir = "/sandbox/.claude/skills"

for s in skills:
    repo = s.get("repo", "") if isinstance(s, dict) else ""
    if not repo:
        continue
    org_repo = repo.rstrip("/").removeprefix("https://github.com/").removesuffix(".git")

    # Clone to detect format
    clone_dir = f"/tmp/skill-repos/{org_repo.replace('/', '-')}"
    cmd = ["git", "clone", "--depth", "1"]
    ref = s.get("ref", "")
    if ref:
        cmd += ["--branch", ref]
    cmd += [repo, clone_dir]

    print(f"  Cloning: {org_repo}" + (f" @{ref}" if ref else ""))
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        err = result.stderr.strip().split("\n")[-1] if result.stderr else "unknown"
        print(f"  WARNING: failed to clone {org_repo}: {err}")
        continue

    # Auto-detect: marketplace plugin or raw skill directories?
    if os.path.isdir(os.path.join(clone_dir, ".claude-plugin")):
        print(f"  → Marketplace plugin: {org_repo}")
        subprocess.run(["claude", "plugin", "marketplace", "add", org_repo],
                       capture_output=True)
    else:
        # Scan for directories containing SKILL.md
        os.makedirs(agents_dir, exist_ok=True)
        os.makedirs(claude_dir, exist_ok=True)
        subpath = s.get("path", "")
        src = os.path.join(clone_dir, subpath) if subpath else clone_dir
        installed = 0
        for root, dirs, files in os.walk(src):
            if "SKILL.md" in files:
                name = os.path.basename(root)
                dest = os.path.join(agents_dir, name)
                if os.path.exists(dest):
                    shutil.rmtree(dest)
                shutil.copytree(root, dest)
                link = os.path.join(claude_dir, name)
                if os.path.lexists(link):
                    os.remove(link)
                os.symlink(dest, link)
                installed += 1
        print(f"  → Installed {installed} skills from {org_repo}")

shutil.rmtree("/tmp/skill-repos", ignore_errors=True)
PYEOF
fi

# ── Configure MCP servers ─────────────────────────────────────────────
python3 /sandbox/configure-mcp.py

echo "Setup complete."

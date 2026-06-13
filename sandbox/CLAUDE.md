# Sandbox Environment

You are running inside an OpenShell sandbox. Credentials are injected via the OpenShell provider system and appear as environment variables automatically.

## Environment

- Working directory: `/sandbox`
- Writable paths: `/sandbox`, `/tmp`
- Inference routes through the gateway proxy at `inference.local`
- Credentials are managed by OpenShell and cleaned up on sandbox exit
- Pre-installed tools: `python3`, `uv`, `node`, `npm`, `git`, `curl`
- MCP servers are configured in `.mcp.json` and connected automatically

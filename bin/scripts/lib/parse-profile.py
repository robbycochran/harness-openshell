#!/usr/bin/env python3
"""Parse a profile TOML file and output shell variable assignments.

Usage:
  python3 parse-profile.py <profile.toml>

Output (eval-safe shell assignments):
  SANDBOX_NAME='agent'
  SANDBOX_IMAGE='quay.io/...'
  SANDBOX_COMMAND='claude --bare'
  SANDBOX_KEEP='true'
  SANDBOX_PROVIDERS='github vertex-local atlassian'
  SANDBOX_ENV='export KEY=value\n...'
"""
import shlex
import sys

try:
    import tomllib
except ImportError:
    import tomli as tomllib

if len(sys.argv) < 2:
    print("Usage: parse-profile.py <profile.toml>", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1], "rb") as f:
    c = tomllib.load(f)

print(f"SANDBOX_NAME={shlex.quote(c.get('name', 'agent'))}")
print(f"SANDBOX_IMAGE={shlex.quote(c.get('image', ''))}")
print(f"SANDBOX_COMMAND={shlex.quote(c.get('command', 'claude --bare'))}")
print(f"SANDBOX_KEEP={shlex.quote(str(c.get('keep', True)).lower())}")

providers = c.get("providers", [])
print(f"SANDBOX_PROVIDERS={shlex.quote(' '.join(providers))}")

env = c.get("env", {})
lines = [f"export {k}={v}" for k, v in env.items()]
print(f"SANDBOX_ENV={shlex.quote(chr(10).join(lines) + chr(10))}")

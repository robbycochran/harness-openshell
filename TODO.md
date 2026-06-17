# TODO — Roadmap

## Next up

### `harness init`
- [ ] Generate a default `harness.yaml` in the current directory
- [ ] Detect available credentials and suggest providers
- [ ] Print next steps ("run `harness apply -f harness.yaml`")
- [ ] Highest-impact missing feature for standalone distribution

### `harness doctor`
- [ ] Check openshell installed and >= 0.0.59
- [ ] Check podman/docker running
- [ ] Check gateway reachable
- [ ] Check credentials available (GITHUB_TOKEN, ADC, JIRA, GWS)
- [ ] Actionable error messages ("install with: brew tap nvidia/openshell...")

### registerProviders should filter by agent's provider list
- `registerProviders()` in `cmd/providers.go` registers all providers regardless
  of what the agent needs. Fix: filter by `agentCfg.ProviderNames()`.

## CLI [DONE]

- [x] `harness apply` with `--dry-run`, `-o yaml|json`, `--attach`, `-f`, `--task`, `--entrypoint`
- [x] `harness get agents|providers|gateways` with `-o table|json|yaml`
- [x] `harness describe <name>` with `-o table|json|yaml`
- [x] `harness delete <name>` with `--all`, `--sandboxes`, `--providers`, `--k8s`
- [x] `harness deploy [local|ocp|kind]`
- [x] Headless task mode: `--task "text"` or `--task @file` runs agent with `--print`
- [x] `kind: policy` applied via `openshell policy set` after sandbox creation
- [x] `teardown` and `status` as hidden deprecated aliases
- [x] `up`, `create`, `render`, `start`, `stop` removed

## Agent Config [DONE]

- [x] Multi-document harness YAML (`kind: agent/provider/gateway/payload/policy`)
- [x] `kind: payload` with `sandbox_path`/`local_path`/`content` + multi-upload
- [x] Agent-level `payloads:` list merged with document-level payloads
- [x] `kind: config` kept as silent alias for backwards compat
- [x] Image defaults overridable via payloads (no image rebuild needed)

### Config reconciliation (`apply -o yaml`) -- future
- [ ] Show where each value came from (default, profile, harness file, env var)
- [ ] Credentials rendered as `${VAR}` placeholders
- [ ] Round-trip: `apply -o yaml > snapshot.yaml && apply -f snapshot.yaml`

### Future fields
- [ ] `description` -- one line of human-readable context per agent config
- [ ] `repo` -- git URL to clone into the sandbox at start

## Testing [DONE]

- [x] Config test suite: 37 tests across 7 categories
- [x] Agent integration: claude + opencode inference, gh cli, jira mcp, gws gmail
- [x] CI: config-suite + test-suite-live in workflows

## Architecture (future)

### Direct gRPC
- OpenShell gateway exposes 54 gRPC RPCs
- Would eliminate CLI binary dependency and output parsing fragility
- Prerequisite: proto files stabilize (OpenShell is alpha)

### Upstream issues to track
- #1719 -- K8s Operator design (affects provider CRDs)
- #1851 -- Plugin system (affects binary naming)
- #1886 -- Declarative provider config in gateway.toml
- #1922 -- Portable sandbox log collection
- #1933 -- Centralized audit/event log

## Observability & Tracing

Langfuse hooks plugin working. MLflow spiked. SigNoz identified as strongest
OTel backend. Integration deferred until `init`/`doctor` ship.

## Release

- [x] CHANGELOG.md + LICENSE (Apache 2.0)
- [ ] `harness init` for standalone binary distribution

# TODO — Go Migration & Roadmap

## Migration Status

| Command | Go Status | Notes |
|---------|-----------|-------|
| `up --local` | Native | Full flow: deploy + providers + sandbox create with retry |
| `up --remote` | Native | K8s Job YAML via internal/k8s, prerequisite chain (deploy+providers+creds) |
| `create` | Native | Sandbox creation only (no deploy/providers) |
| `connect` | Native | exec into `openshell sandbox connect` |
| `deploy --local` | Native | Podman check, gateway find/select/verify |
| `deploy --remote` | Native | Helm install, Route, mTLS, RBAC, SCCs via internal/k8s |
| `teardown --sandboxes` | Native | SandboxList + SandboxDelete via Gateway |
| `teardown --providers` | Native | ProviderList + ProviderDelete + InferenceRemove |
| `teardown --k8s` | Native | Helm uninstall, CRDs, SCCs, secrets, namespace via internal/k8s |
| `preflight` | Native | All 29 bats tests pass against Go |
| `providers` | Native | Eliminates jq dependency |
| `test` | Bash | test-flow.sh orchestration (intentionally stays bash) |
| **Launcher** | Native | In-cluster Go binary, UBI9 + openssh |

**Score: 12/13 paths native Go.** Only `test` stays bash (test orchestration, not a user command).

## Architecture Improvements

### Image registry as gateway config vs env override
- gateway.toml `[images]` section sets sandbox/launcher image refs
- `SANDBOX_IMAGE`/`LAUNCHER_IMAGE` env vars override config (for dev/CI)
- Two sources of truth: gateway.toml hardcodes a registry, env vars override it
- Consider: gateway.toml uses a `registry` field and images are relative to it,
  or gateway.toml supports variable expansion (`${REGISTRY}:sandbox`)
- Not urgent — env override approach works as a bridge

### Direct gRPC (future)
- OpenShell gateway exposes 54 gRPC RPCs (proto files in NVIDIA/OpenShell repo)
- Generate Go stubs from proto files → `gateway.GRPC` implementation
- Swap `gateway.NewCLI(cli)` → `gateway.NewGRPC(conn)` — one line change
- Eliminates: openshell CLI binary dependency, output parsing fragility
- Prerequisite: proto files stabilize (OpenShell is alpha)

### Remove Python dependency
- `providers.py` and `parse-profile.py` still in repo, called by bash path (`bin/harness`)
- Go implementations exist: `internal/preflight/` and `internal/profile/`
- Remove when: bash path is no longer needed for dual-testing
- Blocked by: decision to stop maintaining bash path

### Launcher consolidation — DONE (#50)
- ~~`sandbox/launcher/` is a separate Go module~~ → deleted, replaced by `harness launch`
- ~~Has its own `parseConfig` duplicating `internal/profile/`~~ → uses `internal/agent/`
- Single binary, single image (`:runner`), single config format (`agents/*.yaml`)

## Agent Schema

The agent config format is `agents/*.yaml` (YAML). TOML profiles are removed.

### Future fields

- [ ] `description` — one line of human-readable context per agent config
- [ ] `repo` — git URL to clone into the sandbox at start
- [ ] `secrets` — non-provider secrets to inject, cleaner than stuffing credentials into `env:`

## Low-Priority Cleanup (from audit)

- [ ] Unexport internal-only functions in `internal/preflight/` and `internal/profile/`
- [ ] `SandboxExec`/`SandboxUpload` on Gateway interface — no callers yet (premature abstraction, but harmless)

## Testing

### Current coverage
- 38 Go unit tests (gateway, profile, cmd)
- 7 launcher tests
- 29 bats preflight tests (Python + Go paths)
- Integration: `{bash, go}` × `{podman, ocp}` via `make validate`
- `--reuse-gateway` for fast OCP cycles (49s vs 137s)

### Gaps to fill
- [ ] Integration test for `providers --force` (currently no test exercises force mode)
- [ ] Go + OCP integration (`test-flow.sh ocp --full --go`) — not yet validated
- [ ] Preflight Go unit tests (internal/preflight/ has no _test.go)
- [ ] Kind gateway integration — `gateways/kind/gateway.toml` exists with full config (direct mode, nodeport) but is not exercised by test-flow.sh or CI. Add `test-flow.sh kind` and a GHA workflow with `kind create cluster`.

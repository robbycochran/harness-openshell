# Harness-OpenShell Code Review: Prioritized Recommendations

10 independent reviewers scored the repo across 8 dimensions. Weighted average: **5.3/10**.

The code architecture is sound (7-8/10) but the documentation is broken (3/10), multi-user support is missing (3/10), and test coverage has critical gaps (4/10). The codebase is ~2100 lines of CLI glue designed to shrink as upstream OpenShell absorbs workarounds — a compiled rewrite would be counterproductive.

| Dimension | Score |
|---|---|
| New Engineer Onboarding | 3 |
| Bash Code Quality | 6 |
| Security | 5 |
| Architecture | 7 |
| Testing | 4 |
| Upstream Alignment | 7 |
| Developer Workflow | 6 |
| Team Scaling (20-person) | 3 |
| Rewrite Analysis | 8 |
| Strategic Direction | 6 |

---

## 1. README Is Completely Broken

**Impact: Blocks every new user on step one.**

Every Quick Start command references scripts deleted in commit `c12db4d`. The Files table lists 9 nonexistent files. `agents/` references should be `profiles/`. Test paths are wrong. No prerequisites listed. No mention of `bin/harness` CLI or how to add it to PATH.

**What to fix:**
- Rewrite Quick Start to use `harness deploy --local`, `harness providers`, `harness new --local`
- Replace Files table with actual structure: `bin/harness`, `bin/scripts/*.sh`, `profiles/default.toml`, `sandbox/`, `test/`
- Replace all `agents/` references with `profiles/`
- Add Prerequisites section (openshell, python3 3.11+, podman/docker, gcloud, bats)
- Add "How to use the CLI" section with PATH setup and `harness --help` output
- Add "Why use a sandbox instead of local Claude?" section (credential isolation, network policy, reproducibility)
- Fix test command paths to `test/test-flow.sh` or `harness test`

**Effort:** 2-3 hours
**Flagged by:** Onboarding (critical x3), Developer Workflow (high), Strategic Direction (medium)

---

## 2. Multi-User Is Fundamentally Broken

**Impact: Cannot deploy to a 20-person team without credential collision and sandbox name conflicts.**

Five independent single-user assumptions block team scaling:

| Problem | Where | Consequence |
|---|---|---|
| Sandbox name hardcoded to "agent" | `profiles/default.toml:7` | Two users overwrite each other's ConfigMap |
| Provider names are gateway-global | `providers.sh:76,118` | All 20 users share one GITHUB_TOKEN |
| GWS creds are a single user's OAuth | `creds.sh:54` | All sandboxes mount one person's Gmail |
| Teardown kills all sandboxes | `teardown.sh:63-69` | One user nukes the team |
| Shared Vertex AI quota | `providers.sh:96-99` | 20 sessions exhaust rate limits |

**What to fix:**
Introduce a `$HARNESS_USER` variable (default: `$USER`) that prefixes:
- Sandbox names: `agent` becomes `rcochran-agent`
- Provider names: `github` becomes `github-rcochran`
- K8s secrets: `openshell-gws` becomes `openshell-gws-rcochran`
- Teardown filter: only delete sandboxes matching `$HARNESS_USER-*`

This is a ~50-line change across `new.sh`, `providers.sh`, `creds.sh`, and `teardown.sh`.

**Effort:** 1 day
**Flagged by:** Team Scaling (critical x2, high x4), Security (high)

---

## 3. Dead Code Cleanup

**Impact: Reduces confusion, aligns codebase with stated "shrink, not grow" principle.**

| File | Lines | Why dead |
|---|---|---|
| `sandbox-local.sh` | 106 | Superseded by `bin/scripts/new.sh --local` |
| `sandbox/configure-mcp.py` | 71 | `mcp.json` baked into image; startup.sh never calls this |
| `sandbox/__pycache__/` | -- | Artifact of dead configure-mcp.py |

**Effort:** 30 minutes
**Flagged by:** Architecture (medium), Upstream Alignment (medium x2), Developer Workflow (low), Strategic Direction (medium)

---

## 4. Security: Gateway Auth and Cluster Permissions

**Impact: Defense-in-depth failures that become critical at team scale.**

**4a. Gateway allows unauthenticated users**
`values-ocp.yaml:29` sets `allowUnauthenticatedUsers: true`. mTLS is the only gate. If mTLS misconfigures, the gateway is open. Fix: enable OIDC auth in addition to mTLS.

**4b. cluster-admin ClusterRoleBinding**
`deploy.sh:111-113` grants `cluster-admin` to the sandbox controller. Unrestricted access to every secret in every namespace. Fix: scope the ClusterRole to Sandbox CRDs, pods, and services in the openshell namespace.

**4c. Privileged SCC on three service accounts**
`deploy.sh:107-110` grants privileged SCC to openshell, openshell-sandbox, and `default`. The `default` SA grant is especially dangerous. Fix: use `restricted` or `nonroot-v2` SCC where possible.

**4d. mTLS key written without file permissions**
`deploy.sh:206-210` writes `tls.key` without `chmod 600`. Fix: add `chmod 600` immediately after writing.

**Effort:** 4-6 hours
**Flagged by:** Security (high x4), Team Scaling (high)

---

## 5. Test Coverage Gaps

**Impact: The most critical code paths (profile parsing, provider flag building, error handling) have zero tests.**

**What has tests:** `providers.py` preflight checks — 29 bats tests, thorough and well-structured.

**What has no tests:**

| Code | Risk | Why it matters |
|---|---|---|
| `lib/profile.sh` (parse_agent, build_provider_flags, stage_harness_dir) | Uses `eval` on Python output | Shell injection if quoting breaks |
| `lib/common.sh` (require_cli, export_gws_creds) | Credential handling | Silent failures leak or lose creds |
| Error paths in deploy.sh, new.sh, teardown.sh | Missing CLI, missing gateway, running sandboxes | Users see cryptic failures |
| `bin/harness` CLI dispatch | Unknown commands, help text | No verification that help matches reality |

All testable offline using the same stub pattern as `preflight.bats`.

**Effort:** 1-2 days for profile.sh + common.sh bats tests; 1 day for error path tests
**Flagged by:** Testing (high x3), Developer Workflow (medium)

---

## 6. DRY Violations: Three Duplicated Patterns

**Impact: Bugs fixed in one copy will not be fixed in the other.**

| Pattern | Copies | Files |
|---|---|---|
| TOML parsing via inline Python | 2 | `profile.sh:16-29`, `entrypoint.sh:49-63` |
| Provider flag building loop | 3 | `profile.sh:34-44`, `entrypoint.sh:79-87`, `sandbox-local.sh:46-59` |
| GWS credential export | 3 | `common.sh:42-64`, `profile.sh:60-66`, `sandbox-local.sh:68-83` |

**What to fix:**
- Extract TOML parsing into `lib/parse_profile.py`
- Delete `sandbox-local.sh` (removes 2 of 3 copies)
- Consolidate GWS export into `common.sh:export_gws_creds()` and call from profile.sh

**Effort:** 3-4 hours (mostly after deleting sandbox-local.sh)
**Flagged by:** Code Quality (medium x3), Architecture (medium)

---

## 7. Broken Path in providers.sh

**Impact: Profile import likely fails silently.**

`providers.sh:64` references `$SCRIPT_DIR/sandbox/profiles/` but `SCRIPT_DIR` is `bin/scripts`, so it resolves to `bin/scripts/sandbox/profiles/` which does not exist. Should be `$HARNESS_DIR/sandbox/profiles/`.

**Effort:** 5 minutes
**Flagged by:** Code Quality (high)

---

## 8. Developer Inner Loop Is Too Slow

**Impact: Every sandbox config change requires a multi-arch Docker build + push (minutes).**

Any change to CLAUDE.md, mcp.json, settings.json, startup.sh, or policy.yaml requires `docker buildx build --push` before testing. The `openshell sandbox upload` primitive already exists.

**What to fix:** Add a `harness sync` subcommand that uploads sandbox config files to a running sandbox without rebuilding the image.

**Effort:** 2-3 hours
**Flagged by:** Developer Workflow (high), Strategic Direction (medium)

---

## 9. Retry Loop Masks Root Cause

**Impact: When sandbox creation fails, developers get "Attempt N failed (supervisor race)" with zero diagnostic info.**

`new.sh:98-116` and `entrypoint.sh:113-126` retry 5 times with backoff but capture no stderr. `test-flow.sh` swallows all output with `&>/dev/null`.

**What to fix:** Capture and display stderr from failed `openshell sandbox create` attempts. Add `--verbose` flag. Log actual exit codes.

**Effort:** 1-2 hours
**Flagged by:** Developer Workflow (high), Testing (medium)

---

## 10. Naming Inconsistency: agent vs profile

**Impact: Low but pervasive confusion.**

`profile.sh` defines `parse_agent()`. CLI uses `--profile`. Directory is `profiles/`. PROVIDERS-SPEC.md still says `agents/*.toml`.

**What to fix:** Rename `parse_agent()` to `parse_profile()`, update PROVIDERS-SPEC.md references.

**Effort:** 30 minutes
**Flagged by:** Code Quality (low), Onboarding (high)

---

## Should We Rewrite?

**No. With one exception.**

- The codebase is 2100 lines of CLI glue. 90% is "run this command, check exit code." A Go version would be `os/exec` calls doing the same thing less readably.
- The harness is designed to shrink. AGENTS.md tracks 5 upstream workarounds. Each eliminated removes 50-150 lines.
- Distribution is not an issue. Users already have openshell, kubectl, helm, python3, and podman installed.
- The complexity threshold for rewrite (~5000+ lines, multiple contributors) is not met.

**The one exception: the in-cluster launcher.** `sandbox/launcher/entrypoint.sh` (138 lines) runs inside a K8s Job, shells out to Python for TOML parsing, and patches gateway metadata.json. A Go binary would produce a scratch-based image (~50MB vs current), eliminate the python3/tomli runtime dependency, and speed up Job startup. A Go rewrite spec already exists at `sandbox/launcher/SPEC.md`.

**Recommendation:** Rewrite the launcher only. Leave everything else as bash+python. Revisit if the harness exceeds 15 scripts or 3000 lines.

---

## Strategic Direction

The harness's destiny is to shrink into upstream OpenShell contributions:
1. Submit `sandbox/Dockerfile` as an OpenShell-Community sandbox
2. Upstream the `atlassian.yaml` provider profile
3. Reduce this repo to team-specific profile TOML files and a thin README

The 10x multiplier is multi-tenant team profiles (`profiles/collector.toml`, `profiles/scanner.toml`) that let the whole RHACS org share one gateway with per-team sandboxes.

---

## Next 3 Things To Do

### 1. Fix the README (2-3 hours)
Single highest-leverage change. Every new user currently fails on step one. Rewrite Quick Start with actual CLI commands, replace Files table, add prerequisites, add PATH setup.

### 2. Delete dead code + fix providers.sh path (1 hour)
Remove `sandbox-local.sh`, `sandbox/configure-mcp.py`, `sandbox/__pycache__/`. Fix `$SCRIPT_DIR` to `$HARNESS_DIR` on `providers.sh:64`. Eliminates 177 lines and fixes broken provider import.

### 3. Add $HARNESS_USER namespacing (1 day)
Prefix sandbox names, provider names, K8s secrets, and teardown filters with `$HARNESS_USER`. Gate to multi-user operation. ~50 lines across 4 files.

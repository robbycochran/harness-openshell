# Agent Observability Spike

## Problem

When running multiple agent sessions on the OCP cluster, there's no way to:
- See what agents are doing in real time
- Search past agent activity across sessions
- Debug why a task failed or what tools were called
- Compare agent behavior across runs

## Goals

1. Structured logs from every agent session, queryable by session/agent/time/tool
2. Web UI accessible from browser — search, filter, live tail
3. Works with what's already on the cluster or easily installable
4. Minimal per-sandbox overhead (no custom sidecars if avoidable)

## Architecture

### Data Sources

Three layers of structured data:

| Source | Format | What it captures |
|--------|--------|-----------------|
| Claude Code `--output-format stream-json` | JSONL | Every assistant message, tool call, tool result, thinking block, token usage |
| OpenShell supervisor OCSF logs | JSONL | Network decisions, process lifecycle, policy enforcement, SSH events |
| Harness metadata | Labels/annotations | Session name, profile, who started it, which tools enabled |

### Option A: Loki + Grafana (OCP-native, recommended)

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────┐
│  Sandbox Pod     │────▶│  Loki        │────▶│  Grafana    │
│  stdout/stderr   │     │  (log store) │     │  (web UI)   │
│  JSONL output    │     │              │     │  search,    │
│                  │     │  labels:     │     │  filter,    │
│  supervisor OCSF │     │  - sandbox   │     │  live tail  │
│  claude stream   │     │  - agent     │     │             │
└─────────────────┘     │  - session   │     └─────────────┘
                        └──────────────┘
```

**How it works:**
- OCP cluster logging (Vector/Fluentd → Loki) already collects pod stdout
- Claude Code JSONL goes to stdout → captured automatically
- Supervisor OCSF logs go to stderr → captured automatically
- Pod labels (`openshell.ai/sandbox-id`, session name) become Loki labels
- Grafana provides search UI, dashboards, live tail

**What's needed:**
- Enable OpenShift Logging operator (if not already installed)
- Configure LokiStack CR in the cluster
- Create Grafana dashboards for agent activity
- Configure Claude Code to output structured JSON in the harness

**Pros:** Zero per-sandbox config. Uses OCP's built-in log pipeline. Grafana is already familiar.
**Cons:** Loki is text-based search, not field-level structured queries. Log retention is cluster-scoped.

### Option B: OpenSearch + Dashboards

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────┐
│  Sandbox Pod     │────▶│  OpenSearch  │────▶│  Dashboards  │
│  stdout/stderr   │     │  (index)     │     │  (web UI)    │
│  JSONL output    │     │              │     │  full-text + │
│                  │     │  structured  │     │  field search│
│  supervisor OCSF │     │  field index │     │              │
└─────────────────┘     └──────────────┘     └──────────────┘
```

**How it works:**
- OCP cluster logging can route to OpenSearch instead of Loki
- JSONL output is parsed into structured fields (tool name, model, tokens, etc.)
- OpenSearch supports field-level queries: "show me all Bash tool calls that failed"
- Dashboards (Kibana fork) provides rich filtering and visualization

**Pros:** Full structured field search. Better for high cardinality (many tools, many sessions).
**Cons:** Heavier to run. More storage. More setup.

### Option C: Lightweight custom viewer (PVC + web app)

```
┌─────────────────┐     ┌──────────────┐     ┌──────────────┐
│  Sandbox Pod     │────▶│  Shared PVC  │────▶│  Viewer Pod  │
│  writes JSONL    │     │  /logs/      │     │  (web app)   │
│  to /logs/       │     │  session-1/  │     │  search,     │
│                  │     │  session-2/  │     │  browse,     │
│                  │     │  ...         │     │  live tail   │
└─────────────────┘     └──────────────┘     └──────────────┘
```

**How it works:**
- Shared PVC (ReadWriteMany) mounted in every sandbox at `/logs/`
- Claude Code output tee'd to `/logs/<session-name>/claude.jsonl`
- Supervisor OCSF logs tee'd to `/logs/<session-name>/ocsf.jsonl`
- Small viewer pod serves a web UI that reads the PVC
- Search via `grep`/`jq` or a small sqlite index

**Pros:** Simplest. No operators. Total control over format. Works on any cluster.
**Cons:** No real-time streaming. Manual index. PVC storage limits. RWX storage class needed.

## Recommendation

**Start with Option A (Loki + Grafana)** if OpenShift Logging is available on the cluster. It's the lowest effort and uses the standard OCP observability stack.

**Fall back to Option C** if cluster logging isn't available or too heavy. It's the simplest to build and gives you the core use case (search past sessions, browse activity).

**Option B** is overkill unless you have 10+ concurrent agents and need field-level analytics.

## Implementation Steps (Option A)

### Phase 1: Enable structured output (harness changes only)

1. Add `--output-format stream-json` to the claude launch command
2. Tee claude output to both terminal and stdout (so cluster logging captures it)
3. Add session labels to sandbox pods via the harness
4. Verify logs appear in Loki via `oc logs` or Grafana

### Phase 2: Install/configure logging stack

1. Check if OpenShift Logging operator is already installed
2. If not, install via OperatorHub:
   - Loki Operator → create LokiStack
   - Cluster Logging Operator → create ClusterLogging CR
3. Configure log forwarding to include `openshell` namespace
4. Verify pod logs flow to Loki

### Phase 3: Grafana dashboards

1. Create a "Agent Activity" dashboard:
   - Session timeline (start/end, duration)
   - Tool call frequency and latency
   - Token usage per session
   - Errors and failures
2. Create a "Live Agent" panel:
   - Live tail of current session stdout
   - Filter by sandbox name
3. Create saved searches:
   - "All Jira tool calls today"
   - "Failed tool invocations"
   - "Sessions by agent profile"

### Phase 4: Enrichment (optional)

1. Parse Claude Code JSONL in a log pipeline (Vector transform)
2. Extract structured fields: tool_name, tool_result_status, model, tokens_in, tokens_out
3. Create Loki structured metadata labels for fast filtering
4. Build cost tracking (tokens × price per model)

## Implementation Steps (Option C fallback)

### Phase 1: Shared log PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agent-logs
  namespace: openshell
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Gi
```

Mount in sandbox pods (same pattern as the policy ConfigMap).

### Phase 2: Log capture in harness

```shell
# In the startup script
LOGDIR="/logs/$(date +%Y%m%d)-${SANDBOX_NAME}"
mkdir -p "$LOGDIR"
claude --output-format stream-json --dangerously-skip-permissions \
  2>&1 | tee "$LOGDIR/claude.jsonl"
```

### Phase 3: Viewer

A simple Go/Python web app:
- Serves at `agent-logs.openshell.svc:8080`
- Lists sessions by date
- Renders JSONL as a conversation view
- Full-text search via grep/ripgrep
- Expose via OCP Route for browser access

## Claude Code Structured Output Fields

When `--output-format stream-json` is used, each line is a JSON object:

```json
{"type": "assistant", "message": {"role": "assistant", "content": [...]}, "usage": {"input_tokens": 1234, "output_tokens": 567}}
{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}
{"type": "tool_result", "name": "Bash", "content": "file1.txt\nfile2.txt", "is_error": false}
{"type": "system", "message": "Session started", "session_id": "abc123"}
```

Key fields for search/filtering:
- `type` — assistant, tool_use, tool_result, system, error
- `name` — tool name (Bash, Read, Write, mcp__atlassian__*, etc.)
- `is_error` — whether the tool call failed
- `usage.input_tokens`, `usage.output_tokens` — cost tracking

## Open Questions

1. Does the OCP cluster have OpenShift Logging installed? (`oc get csv -n openshift-logging`)
2. Is there a default RWX storage class? (needed for Option C shared PVC)
3. What retention do you want? 7 days? 30 days? Indefinite?
4. Should the viewer be accessible outside the cluster (OCP Route) or only via port-forward?

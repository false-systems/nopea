# NOPEA: AI-Native Deployment Tool with Memory

---

## WHAT IS NOPEA

Nopea is a deployment tool that builds a knowledge graph from every deployment. The core innovation: **memory**. Every existing tool (ArgoCD, Flux, Helm) treats each deploy as the first deploy ever. Nopea learns.

**NOT a GitOps controller.** No CRDs, no git sync, no reconciliation loops. Nopea is a CLI/API tool that deploys manifests to Kubernetes and remembers what happened.

---

## ARCHITECTURE

```
CLI/MCP/API → Deploy.deploy(spec)
    → ServiceAgent.deploy()              # queue/serialize per-service
    → Deploy.run(spec)                   # orchestration
    → Memory.get_deploy_context()        # graph query
    → select_strategy()                  # direct/canary/blue_green (memory-aware)
    → Strategy.Direct.execute()          # K8s server-side apply
    → Drift.verify_manifest()            # post-deploy 3-way diff
    → Memory.record_deploy()             # graph update (EWMA)
    → Occurrence.build() + persist()     # FALSE Protocol
```

### OTP Supervision Tree

```
Nopea.Application
├── Nopea.ULID                       # Monotonic ID generator
├── TelemetryMetricsPrometheus       # Metrics (optional)
├── Nopea.Events.Emitter             # CDEvents HTTP emitter (optional)
├── Nopea.Cache                      # ETS tables for deployment state
├── Nopea.Memory                     # GenServer wrapping knowledge graph
├── Nopea.Cluster                    # libcluster (optional, cluster mode)
├── Nopea.Registry / DistributedRegistry  # Process registry
├── Nopea.ServiceAgent.Supervisor    # DynamicSupervisor for per-service agents
└── Nopea.API.Router                 # Plug/Cowboy HTTP (optional)
```

---

## KEY MODULES

| Module | Role | Lines |
|--------|------|-------|
| `Deploy` | Orchestration: context → strategy → execute → verify → record | ~400 |
| `Deploy.Spec` / `Result` | Structs for deploy lifecycle | ~100 |
| `ServiceAgent` | Per-service GenServer: queue, serialize, backpressure | ~340 |
| `ServiceAgent.Supervisor` | DynamicSupervisor for ServiceAgent processes | ~25 |
| `Strategy.Direct` | Immediate K8s apply | ~20 |
| `Kulta.RolloutBuilder` | Build Kulta Rollout CRDs for canary/blue_green | ~100 |
| `Memory` | GenServer owning `Graph.t()` with EWMA decay | ~150 |
| `Memory.Ingestor` | Deploy events → graph upsert operations | ~100 |
| `Memory.Query` | Context queries (failure patterns, deps) | ~100 |
| `Graph.*` | Knowledge graph: Graph, Node, Relationship, Identity, EWMA | ~400 |
| `Occurrence` | FALSE Protocol occurrence generator | ~150 |
| `MCP` | JSON-RPC MCP server (tools/list, tools/call) | ~300 |
| `API.Router` | HTTP API (deploy, context, history endpoints) | ~100 |
| `SYKLI.Target` | SYKLI target behaviour adapter | ~80 |
| `CLI` | Escript entry point | ~145 |
| `K8s` | K8s API wrapper (conn, apply, get, delete) | ~70 |
| `Applier` | YAML parsing + K8s server-side apply | ~200 |
| `Drift` | Three-way drift detection (normalize, diff, verify) | ~250 |
| `Cache` | ETS tables: deployments, service_state, graph_snapshot | ~100 |
| `Events` / `Events.Emitter` | CDEvents builder + async HTTP emitter | ~200 |
| `ULID` | Monotonic ULID generator | ~80 |

---

## FILE LOCATIONS

| What | Where |
|------|-------|
| OTP Application | `lib/nopea/application.ex` |
| Deploy orchestration | `lib/nopea/deploy.ex` |
| Deploy structs | `lib/nopea/deploy/spec.ex`, `result.ex` |
| ServiceAgent | `lib/nopea/service_agent.ex`, `service_agent/supervisor.ex` |
| Strategy behaviour | `lib/nopea/strategy.ex` |
| Strategy impl | `lib/nopea/strategy/direct.ex` |
| Kulta rollout builder | `lib/nopea/kulta/rollout_builder.ex` |
| Memory | `lib/nopea/memory.ex` |
| Memory helpers | `lib/nopea/memory/ingestor.ex`, `query.ex` |
| Knowledge graph | `lib/nopea/graph/graph.ex`, `node.ex`, `relationship.ex`, `identity.ex`, `ewma.ex` |
| FALSE Protocol | `lib/nopea/occurrence.ex` |
| MCP server | `lib/nopea/mcp.ex` |
| HTTP API | `lib/nopea/api/router.ex` |
| SYKLI integration | `lib/nopea/sykli/target.ex` |
| CLI | `lib/nopea/cli.ex` |
| K8s client | `lib/nopea/k8s.ex`, `k8s/behaviour.ex` |
| YAML + apply | `lib/nopea/applier.ex` |
| Drift detection | `lib/nopea/drift.ex` |
| Cache (ETS) | `lib/nopea/cache.ex` |
| Events | `lib/nopea/events.ex`, `events/emitter.ex` |
| Metrics | `lib/nopea/metrics.ex` |
| ULID | `lib/nopea/ulid.ex` |
| Clustering | `lib/nopea/cluster.ex`, `distributed_registry.ex`, `distributed_supervisor.ex` |

---

## DEPENDENCIES

| Package | Purpose |
|---------|---------|
| `false_protocol` | FALSE Protocol occurrence generation |
| `k8s` | Kubernetes client |
| `yaml_elixir` | YAML parsing |
| `jason` | JSON |
| `plug_cowboy` | HTTP server |
| `req` | HTTP client (CDEvents) |
| `libcluster` | BEAM clustering (optional) |
| `horde` | Distributed supervisor/registry (optional) |
| `telemetry` + `telemetry_metrics` + `prometheus_core` | Observability |
| `mox` | Test mocking (test only) |
| `credo` | Linting (dev/test only) |

**No Rust. No msgpax. No git operations.**

---

## ELIXIR PATTERNS

### Error Handling

```elixir
# Use {:ok, _} / {:error, _} tuples, not bare raise
with {:ok, conn} <- K8s.conn(),
     {:ok, applied} <- Applier.apply_manifests(manifests, conn, ns) do
  {:ok, applied}
end
```

### Logging

```elixir
require Logger
Logger.info("Deploy completed", service: service, deploy_id: deploy_id, duration_ms: duration_ms)
# No IO.puts, no IO.inspect in production code
# Use structured metadata — keys configured in config/config.exs
```

### Atoms not Strings

```elixir
# Status: :completed, :failed — not "completed", "failed"
# Strategy: :direct, :canary, :blue_green — not strings
```

### K8s Mock Pattern

`Nopea.K8s` implements `Nopea.K8s.Behaviour`. In tests, `Nopea.K8sMock` (Mox) is injected via:

```elixir
# test_helper.exs
Application.put_env(:nopea, :k8s_module, Nopea.K8sMock)

# Direct.execute uses:
defp k8s_module, do: Application.get_env(:nopea, :k8s_module, Nopea.K8s)

# Tests that don't set explicit expectations:
setup do
  Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
  # Stub get_resource — no real cluster in tests
  Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ -> {:error, :not_found} end)
  :ok
end

# Tests with spawned processes (ServiceAgent):
setup :set_mox_global
```

---

## TDD WORKFLOW

**RED → GREEN → REFACTOR** — Always.

1. Write failing test
2. Verify it fails
3. Write minimal implementation
4. Verify all tests pass
5. Refactor, add edge cases
6. Run `mix format && mix compile --warnings-as-errors && mix test`

---

## VERIFICATION

```bash
mix compile --warnings-as-errors
mix test                          # 280 tests, 0 failures
mix format --check-formatted
mix credo
mix escript.build                 # CLI binary
```

---

## MEMORY SYSTEM

The memory is a knowledge graph stored in the `Nopea.Memory` GenServer state.

**Graph nodes**: services, namespaces, errors (kinds: `:concept`, `:error`)
**Graph relationships**: `:deployed_to`, `:breaks`, `:deployed_together`
**EWMA decay**: Weights decay hourly (factor 0.98) so recent deploys matter more

Key queries:
- `Memory.get_deploy_context(service, namespace)` → failure patterns, recommendations
- `Memory.record_deploy(result)` → ingest into graph (cast)
- `Memory.node_count()` / `Memory.relationship_count()` → graph stats

---

## FALSE PROTOCOL

Occurrences are structured events generated after every deployment.

**Types**: `deploy.run.completed`, `deploy.run.failed`, `deploy.run.rolledback`
**Blocks**: error, reasoning (includes memory context), history, deploy_data
**Storage**: `.nopea/occurrence.json` (cold) + `.nopea/occurrences/*.etf` (warm)

---

## MCP SERVER

JSON-RPC 2.0 over stdin/stdout. Tools:

| Tool | Description |
|------|-------------|
| `nopea_deploy` | Deploy manifests to K8s |
| `nopea_context` | Get memory context for a service |
| `nopea_history` | Get deployment history |
| `nopea_health` | Check health of active service agents |
| `nopea_explain` | Explain strategy selection reasoning |

---

## STRATEGY AUTO-SELECTION

```elixir
# Explicit strategy always wins
defp select_strategy(%Spec{strategy: strategy}, _context)
     when strategy in [:direct, :canary, :blue_green] do
  strategy
end

# Memory-based: known service with high failure confidence → canary
defp select_strategy(%Spec{strategy: nil}, %{known: true, failure_patterns: patterns})
     when is_list(patterns) do
  threshold = Application.get_env(:nopea, :canary_threshold, 0.15)
  if Enum.any?(patterns, fn p -> p.confidence > threshold end), do: :canary, else: :direct
end

# Default: direct
defp select_strategy(%Spec{strategy: nil}, _context), do: :direct
```

---

## AGENT INSTRUCTIONS

1. **Read first** — understand the module before changing it
2. **TDD always** — write failing test, implement, refactor
3. **No stubs** — complete implementations only
4. **Typespecs required** — all public functions
5. **Run checks** — `mix compile --warnings-as-errors && mix test`
6. **No IO.puts** — use `require Logger`
7. **No bare raise** — use `{:error, reason}` tuples

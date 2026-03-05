# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## WHAT IS NOPEA

Nopea is a deployment tool that builds a knowledge graph from every deployment. The core innovation: **memory**. Every existing tool (ArgoCD, Flux, Helm) treats each deploy as the first deploy ever. Nopea learns.

**NOT a GitOps controller.** No CRDs, no git sync, no reconciliation loops. Nopea is a CLI/API tool that deploys manifests to Kubernetes and remembers what happened.

---

## BUILD AND TEST COMMANDS

```bash
# Full verification (run after every change)
mix format && mix compile --warnings-as-errors && mix test

# Individual commands
mix test                                    # 280 tests, 0 failures
mix test test/nopea/deploy_test.exs         # Single file
mix test test/nopea/deploy_test.exs:106     # Single test by line number
mix test --exclude integration --exclude cluster  # Skip slow tests
mix format --check-formatted
mix credo
mix escript.build                           # CLI binary → ./nopea
```

Tests exclude `:integration` and `:cluster` tags by default (configured in `test_helper.exs`).

---

## DEPLOY PIPELINE

```
CLI/MCP/API → Deploy.deploy(spec)
    → ServiceAgent.deploy()              # queue/serialize per-service
    → Deploy.run(spec)                   # orchestration
    → Memory.get_deploy_context()        # graph query
    → select_strategy()                  # direct/canary/blue_green (memory-aware)
    → Strategy.Direct.execute()          # K8s server-side apply
    → Drift.verify_manifest()            # post-deploy 3-way diff
    → Memory.record_deploy()             # graph update (EWMA, async cast)
    → Occurrence.build() + persist()     # FALSE Protocol
```

**Entry points**: `Deploy.deploy/1` routes through ServiceAgent if the supervisor is running; falls back to `Deploy.run/1` otherwise. Always use `deploy/1` — never call `run/1` directly from external callers.

---

## OTP SUPERVISION TREE

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

### Configuration Feature Flags

Most children are optional, controlled by `Application.get_env(:nopea, key)`:

| Key | Default | Controls |
|-----|---------|----------|
| `:enable_metrics` | `true` | TelemetryMetricsPrometheus |
| `:enable_cache` | `true` | Nopea.Cache (ETS) |
| `:enable_memory` | `true` | Nopea.Memory (knowledge graph) |
| `:enable_deploy_supervisor` | `true` | Registry + ServiceAgent.Supervisor |
| `:enable_router` | `false` | Nopea.API.Router (HTTP) |
| `:cluster_enabled` | `false` | Cluster + DistributedRegistry |
| `:cdevents_endpoint` | `nil` | Events.Emitter (started only if set) |
| `:canary_threshold` | `0.15` | Failure confidence for auto-canary |

---

## STRATEGY AUTO-SELECTION

```elixir
# Explicit strategy always wins
defp select_strategy(%Spec{strategy: strategy}, _context)
     when strategy in [:direct, :canary, :blue_green], do: strategy

# Memory-based: known service with high failure confidence → canary
defp select_strategy(%Spec{strategy: nil}, %{known: true, failure_patterns: patterns})
     when is_list(patterns) do
  threshold = Application.get_env(:nopea, :canary_threshold, 0.15)
  if Enum.any?(patterns, fn p -> p.confidence > threshold end), do: :canary, else: :direct
end

# Default: direct
defp select_strategy(%Spec{strategy: nil}, _context), do: :direct
```

Canary/blue_green strategies use `Kulta.RolloutBuilder` to create Rollout CRDs. If no Deployment manifest is found in the spec, the strategy fails with `:no_deployment_found`.

---

## SERVICE AGENT

Per-service GenServer that queues and serializes deploys:

- **Queue limit**: 10 — rejects excess with `{:error, :queue_full}`
- **Crash cooldown**: 2s delay before dequeuing after worker crash
- **Idle timeout**: 30 min — agent shuts down if no deploys
- **Lookup**: `ServiceAgent.status(service)` returns `{:ok, %{status: :idle | :deploying, ...}}`
- **Health**: `ServiceAgent.health()` queries all active agents

---

## MEMORY SYSTEM

Knowledge graph stored in `Nopea.Memory` GenServer state.

**Graph nodes**: services, namespaces, errors (kinds: `:concept`, `:error`)
**Graph relationships**: `:deployed_to`, `:breaks`, `:deployed_together`
**EWMA decay**: Weights decay hourly (factor 0.98) so recent deploys matter more

Key API:
- `Memory.get_deploy_context(service, namespace)` → failure patterns, recommendations
- `Memory.record_deploy(result)` → ingest into graph (**async cast**)
- `Memory.node_count()` / `Memory.relationship_count()` → graph stats (**sync call**)

---

## K8S MOCK PATTERN

`Nopea.K8s` implements `Nopea.K8s.Behaviour`. Mox injects `Nopea.K8sMock` in tests via config:

```elixir
# test_helper.exs sets:
Application.put_env(:nopea, :k8s_module, Nopea.K8sMock)

# Production code resolves at runtime:
defp k8s_module, do: Application.get_env(:nopea, :k8s_module, Nopea.K8s)
```

### Test Setup Patterns

**Unit tests** (no spawned processes):
```elixir
setup :verify_on_exit!
setup do
  Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
  Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ -> {:error, :not_found} end)
  :ok
end
```

**Integration tests** (ServiceAgent, spawned workers):
```elixir
setup :set_mox_global          # MUST come before other setup — allows spawned processes to use mocks
setup :verify_on_exit!
setup do
  Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
  start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
  start_supervised!(Nopea.ServiceAgent.Supervisor)
  start_supervised!({Nopea.Memory, []})
  start_supervised!(Nopea.Cache)
  :ok
end
```

### Sync After Async Casts

`Memory.record_deploy/1` is a `cast` — don't use `Process.sleep` to wait for it. Use any `GenServer.call` to the same process as a mailbox flush:

```elixir
# BEAM mailbox FIFO ordering guarantees all prior casts complete before this call returns
_ = Nopea.Memory.node_count()
ctx = Nopea.Memory.get_deploy_context("svc", "ns")
```

### Test Factories

Available in `test/support/factory.ex`:
- `Nopea.Test.Factory.sample_deployment_manifest(name, namespace)`
- `Nopea.Test.Factory.sample_service_manifest(name)`
- `Nopea.Test.Factory.sample_configmap_manifest(name, namespace, data)`

---

## ELIXIR PATTERNS

### Error Handling
```elixir
# {:ok, _} / {:error, _} tuples — no bare raise
with {:ok, conn} <- K8s.conn(),
     {:ok, applied} <- Applier.apply_manifests(manifests, conn, ns) do
  {:ok, applied}
end
```

### Logging
```elixir
require Logger
Logger.info("Deploy completed", service: service, deploy_id: deploy_id, duration_ms: duration_ms)
# Use structured metadata — keys configured in config/config.exs
# No IO.puts or IO.inspect in production code
```

### Atoms not Strings
```elixir
# Status: :completed, :failed — not "completed", "failed"
# Strategy: :direct, :canary, :blue_green — not strings
```

---

## FALSE PROTOCOL

Occurrences are structured events generated after every deployment.

**Types**: `deploy.run.completed`, `deploy.run.failed`, `deploy.run.rolledback`
**Storage**: `.nopea/occurrence.json` (cold) + `.nopea/occurrences/*.etf` (warm)

---

## MCP SERVER

JSON-RPC 2.0 over stdin/stdout. Tools: `nopea_deploy`, `nopea_context`, `nopea_history`, `nopea_health`, `nopea_explain`.

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
| `telemetry` + `prometheus_core` | Observability |
| `mox` | Test mocking (test only) |
| `credo` | Linting (dev/test only) |

---

## AGENT INSTRUCTIONS

1. **Read first** — understand the module before changing it
2. **TDD always** — write failing test, implement, refactor
3. **No stubs** — complete implementations only
4. **Typespecs required** — all public functions
5. **Run checks** — `mix format && mix compile --warnings-as-errors && mix test`
6. **No IO.puts** — use `require Logger` with structured metadata
7. **No bare raise** — use `{:error, reason}` tuples
8. **No Process.sleep in tests** — use GenServer.call barriers for async cast sync

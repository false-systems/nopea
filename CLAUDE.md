# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Core definition

**Nopea is a memory-backed convergence controller for system changes.**

It executes changes (today: Kubernetes deployments), records what happened, and uses accumulated outcomes to influence future executions. Memory is not a feature on top of a deploy tool — it is the architecture.

---

## What Nopea is NOT

- **Not a simple deployment CLI.** A CLI forgets. Nopea cannot.
- **Not GitOps.** No CRDs, no upstream sync, no reconciliation against a git ref.
- **Not stateless.** Every execution depends on prior execution.
- **Not bound to a specific storage backend.** Memory is an abstraction Nopea owns; how it is persisted is an implementation detail and may change.

When a change pulls Nopea toward any of these, it is the wrong direction.

---

## The core loop

```
intent → context → plan → act → verify → learn
```

Every operation traverses every stage. Skipping a stage is a defect.

| Stage | Meaning |
|-------|---------|
| intent | A request to change a system arrives (CLI / MCP / HTTP / Sykli node) |
| context | Memory is consulted for prior outcomes and recurring patterns |
| plan | A strategy is selected, informed by context |
| act | The change is executed |
| verify | Convergence is confirmed |
| learn | The outcome is recorded back into memory |

---

## Invariants

These are not aspirational. Code that violates them is broken regardless of test outcomes.

1. **Every execution produces a structured occurrence.** No silent operations.
2. **Past outcomes must influence future decisions.** Strategy selection consults memory; the consultation is not optional in code paths that need it.
3. **No execution without context evaluation.** There is no fast path that skips the context stage.
4. **Verification precedes progression.** A change is not "done" until convergence is confirmed.
5. **Policy constraints override adaptive behavior.** Explicit intent (a strategy passed in) beats inferred behavior. Future policy hooks sit at the same precedence.
6. **Per-target serialization.** Concurrent executions against the same target are forbidden — they must be queued.
7. **Outcomes are append-only.** Memory flows forward. Past records are not edited.

---

## System boundaries

Nopea is one organ in a larger system. Stay inside Nopea's lines.

| Component | Role |
|-----------|------|
| **Sykli** | Defines execution graphs — what runs, when, under what conditions |
| **Nopea** | Executes deployment-related changes with memory |
| **Syvä** | Enforcement |
| **Jälki** | Observation |
| **Ahti** | Explanation |

If a PR adds Sykli scheduling logic, Syvä enforcement, Jälki observation, or Ahti explanation into Nopea, it has crossed a boundary. Stop and reconsider scope.

---

## Design principles

1. **Stateful execution.** State is the asset. Persistence is non-negotiable.
2. **Explicit intent.** The intent struct carries everything; no hidden globals shape outcomes.
3. **Constrained adaptation.** Memory shifts behavior only inside well-defined seams (strategy selection, risk surfacing). It does not rewrite manifests or invent operations.
4. **Memory as first-class.** Memory APIs are public, tested, and stable — not a sidecar.
5. **Reproducibility over cleverness.** Same intent + same memory state ⇒ same outcome. Random behavior is a defect.

---

## Operational reference

### Build and test

```bash
mix format && mix compile --warnings-as-errors && mix test
mix test test/nopea/deploy_test.exs:106     # single test by line
mix escript.build                            # CLI binary → ./nopea
```

Tests exclude `:integration` and `:cluster` by default (see `test_helper.exs`).

Cluster work via `Makefile`: `make build`, `make docker`, `make kind-load`, `make dev-setup`, `make eval` (full live oracle), `make oracle-local`.

### Where each loop stage lives

| Stage | Code |
|-------|------|
| intent | `Deploy.Spec` constructed by CLI / MCP / HTTP, all routed through `Nopea.Surface` |
| context | `Memory.get_deploy_context/2` |
| plan | `select_strategy/2` in `lib/nopea/deploy.ex` |
| act | `Strategy.{Direct, Canary, BlueGreen}.execute/1` |
| verify | `Drift.verify_manifest/3` (direct) or `Progressive.Monitor` (canary / blue-green) |
| learn | `Memory.record_deploy/1` (async cast → memory + persistence) |

`Deploy.deploy/1` is the only valid external entry point. It routes through `ServiceAgent` for per-service serialization. Never call `Deploy.run/1` directly from outside.

Every traversal of the loop also produces a FALSE Protocol occurrence (`Occurrence.build/persist`), persisted under `.nopea/`. This is enforced by invariant 1, not by the loop itself.

### Per-target queueing

`ServiceAgent` queues deploys per service. When a service's queue is saturated, `Deploy.deploy/1` returns `{:error, :queue_full}` rather than dropping or blocking. The CLI, MCP, and HTTP surfaces all surface this error verbatim.

### Persistence

Memory is persisted to `.nopea/graph.etf`. Restore order on startup: ETS snapshot → disk → fresh state. Wiping the file resets memory.

### Module map

```
lib/nopea/
├── deploy.ex                    # Loop orchestrator (entry: Deploy.deploy/1)
├── deploy/{spec,result}.ex
├── strategy.ex + strategy/{direct,canary,blue_green}.ex
├── service_agent.ex + service_agent/supervisor.ex   # Per-target queue
├── progressive/                 # Rollout monitor (canary / blue-green)
├── memory.ex + memory/          # Memory facade, ingestor, query
├── graph/                       # Memory internals — private to memory.ex
├── surface.ex                   # Unified facade (CLI / MCP / HTTP all route here)
├── api/{router,auth_plug}.ex    # HTTP (Plug/Cowboy) + x-api-key auth
├── mcp.ex                       # MCP JSON-RPC over stdin/stdout
├── cli.ex                       # Escript entry
├── k8s.ex + k8s/behaviour.ex    # K8s client (Mox-injected in tests)
├── applier.ex + drift.ex        # Server-side apply + 3-way drift verify
├── kulta/rollout_builder.ex     # Rollout CRDs for progressive
├── domain/resource_key.ex       # Canonical Kind/Namespace/Name struct
├── occurrence.ex                # FALSE Protocol generator
├── events/emitter.ex            # CDEvents (optional)
├── cluster.ex + distributed_*   # libcluster + Horde (optional)
└── application.ex               # OTP supervision tree
```

External callers go through the `Memory` API. Anything under `memory/` and `graph/` is implementation detail.

### Configuration

Most subsystems are feature-flagged via `Application.get_env(:nopea, …)`; in `:prod` flags are populated from `NOPEA_*` env vars by `config/runtime.exs`.

| Key | Default | Controls |
|-----|---------|----------|
| `:enable_metrics` | `true` | Telemetry / Prometheus |
| `:enable_cache` | `true` | ETS deployment-state cache |
| `:enable_memory` | `true` | Memory subsystem |
| `:enable_deploy_supervisor` | `true` | Registry + ServiceAgent + Progressive supervisors |
| `:enable_router` | `false` | HTTP API |
| `:cluster_enabled` | `false` | libcluster + Horde |
| `:cdevents_endpoint` | `nil` | Events emitter (started only if set) |
| `:canary_threshold` | `0.15` | Adaptive-canary trigger |
| `:api_key` | `nil` | HTTP `x-api-key` requirement (`nil` = open / dev mode) |

### Strategy selection

```elixir
# Explicit intent wins (invariant 5)
defp select_strategy(%Spec{strategy: s}, _) when s in [:direct, :canary, :blue_green], do: s

# Otherwise, memory-driven
defp select_strategy(%Spec{strategy: nil}, %{known: true, failure_patterns: ps}) when is_list(ps) do
  threshold = Application.get_env(:nopea, :canary_threshold, 0.15)
  if Enum.any?(ps, &(&1.confidence > threshold)), do: :canary, else: :direct
end

defp select_strategy(_, _), do: :direct
```

Canary and blue-green return `:progressing`; a `Progressive.Monitor` GenServer (per rollout) polls the Kulta Rollout CRD (10s interval, 1h max) and records the terminal outcome. Manual control: `Surface.promote/1`, `Surface.rollback/1`. Monitors register as `{:rollout, deploy_id}` in `Nopea.Registry`.

### K8s mock (Mox)

`Nopea.K8s` implements `Nopea.K8s.Behaviour`. Tests inject `Nopea.K8sMock` via `:k8s_module` config (set in `test_helper.exs`).

Unit tests:
```elixir
setup :verify_on_exit!
setup do
  Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
  :ok
end
```

Integration tests (spawned processes need global mocks):
```elixir
setup :set_mox_global    # MUST come before other setup
setup :verify_on_exit!
```

Factories: `Nopea.Test.Factory.{sample_deployment_manifest, sample_service_manifest, sample_configmap_manifest}`.

### Async-cast sync

`Memory.record_deploy/1` is a `cast`. Don't `Process.sleep`. Flush the mailbox with any sync `call`:

```elixir
_ = Nopea.Memory.node_count()             # mailbox barrier
ctx = Nopea.Memory.get_deploy_context("svc", "ns")
```

BEAM mailbox FIFO ordering guarantees casts before this call have been processed.

### Oracle (eval)

`eval/oracle/` is a **standalone Mix project** that imports nothing from Nopea internals. It exercises a live instance through public interfaces only (HTTP + MCP). Oracle failures are architectural signals, not bug reports. Run `make oracle-local` (against `localhost:4000`) or `make eval` (full kind deploy + oracle).

### Pre-commit and CI

`scripts/setup-hooks.sh` installs a hook that **rejects** commits with these in `lib/`:
- `raise "..."` (use `{:error, reason}`)
- `IO.puts` / `IO.inspect` (use `Logger`)
- `TODO` / `FIXME`

The hook also runs `mix format --check-formatted`, `mix credo --strict`, and `mix test`. CI (`.github/workflows/ci.yml`) runs the same checks.

### Surface and identity

- `Nopea.Surface` is the facade behind CLI, MCP, and HTTP. It degrades gracefully when optional subsystems are down (e.g., returns `{:error, :unavailable}` rather than crashing).
- HTTP API gated by `Nopea.API.AuthPlug` (`x-api-key` against `:api_key`); `nil` key = dev mode. `/health` and `/ready` always pass.
- `Nopea.Domain.ResourceKey` (`Kind/Namespace/Name`) is the canonical struct between Applier, Cache, Drift, and Events. Prefer it over raw strings.

---

## Working in this repo

1. Read first. Locate the loop stage you're touching.
2. TDD. Write the failing test that captures the invariant you're enforcing.
3. No stubs. No partial implementations.
4. Typespecs on all public functions.
5. After every change: `mix format && mix compile --warnings-as-errors && mix test`.
6. No `IO.puts`, no bare `raise`, no `Process.sleep` in tests (use `GenServer.call` barriers).
7. If a change blurs a system boundary (Sykli / Syvä / Jälki / Ahti), stop and reconsider scope.

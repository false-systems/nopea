# NOPEA

**AI-native deployment tool with memory**

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.14%2B-purple.svg)](https://elixir-lang.org)
[![Tests](https://img.shields.io/badge/tests-235%20passing-green.svg)]()

Every deployment tool treats each deploy as the first deploy ever. Nopea remembers.

**ArgoCD has no memory. Nopea remembers.**

---

## What Is This?

Nopea is a deployment tool that builds a knowledge graph from every deployment. Each deploy makes the next one smarter.

```
Deploy #1: direct apply (no history)
Deploy #2: direct apply (1 success recorded)
Deploy #3: FAILED — recorded failure pattern
Deploy #4: auto-selects canary strategy (learned from #3)
Deploy #5: canary succeeds — confidence updated
```

The graph learns patterns like: *"auth-service deploys fail when redis is also updating"* (0.85 confidence, seen 4 times). Next time an AI agent deploys auth-service, it gets warned.

---

## Quick Start

```bash
# Build
mix deps.get
mix escript.build

# Deploy manifests
./nopea deploy -f manifests/ -s my-app -n default

# Check what Nopea learned
./nopea context my-app --json

# Deploy again — strategy selected based on memory
./nopea deploy -f manifests/ -s my-app -n default

# See deployment history
./nopea history my-app
```

**Requirements:**
- Elixir 1.14+
- Kubernetes 1.22+ (for server-side apply)
- [Kerto](https://github.com/yairfalse/kerto) (knowledge graph, path dependency)

---

## The Memory Loop

```
1. Deploy request arrives (CLI / MCP / HTTP API / SYKLI)
2. Memory.get_deploy_context("my-app", "prod")
   → failure_rate, dependencies, risky patterns, recommendations
3. Strategy auto-selected based on context
   → high failure rate? → canary
   → unknown service? → direct
4. Deploy executes (K8s server-side apply)
5. Post-deploy verification (three-way drift check)
6. Memory records outcome → KERTO graph updated
7. FALSE Protocol occurrence written to .nopea/
8. Next deploy starts at step 2 with MORE context
```

---

## Features

| Feature | Description |
|---------|-------------|
| **Memory** | KERTO knowledge graph learns from every deploy |
| **Strategy Selection** | Auto-selects direct/canary/blue-green based on history |
| **Post-Deploy Verification** | Three-way drift detection confirms deploy applied correctly |
| **FALSE Protocol** | Structured occurrences for AI consumption |
| **MCP Server** | Model Context Protocol for AI agent integration |
| **HTTP API** | REST endpoints for SYKLI and external tools |
| **CLI** | `nopea deploy`, `nopea context`, `nopea history` |
| **CDEvents** | Async deployment events with retry queue |
| **ETS Cache** | In-memory deployment state, no external deps |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         BEAM VM                                  │
│                                                                  │
│  OTP Supervision Tree                                            │
│  ├── ULID           (monotonic ID generator)                     │
│  ├── Metrics        (Telemetry + Prometheus)                     │
│  ├── Events.Emitter (async CDEvents with retry)                  │
│  ├── Memory         (KERTO graph — the brain)                    │
│  ├── Cache          (ETS deployment state)                       │
│  ├── Registry       (process registry)                           │
│  ├── Deploy.Supervisor (DynamicSupervisor for workers)           │
│  └── API.Router     (Plug/Cowboy HTTP, optional)                 │
│                                                                  │
│  Deploy Flow                                                     │
│  CLI/MCP/API → Deploy.run(spec)                                  │
│       → Memory.get_deploy_context()                              │
│       → select_strategy()                                        │
│       → Strategy.Direct/Canary/BlueGreen.execute()               │
│       → K8s.apply_manifests() (server-side apply)                │
│       → Drift.verify_manifest() (post-deploy check)              │
│       → Memory.record_deploy() (graph update)                    │
│       → Occurrence.build() + persist() (FALSE Protocol)          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Interfaces

### CLI

```bash
nopea deploy -f <path> -s <service> -n <namespace> [--strategy direct|canary|blue_green]
nopea status <service>
nopea context <service> [--json]
nopea history <service>
nopea memory
nopea serve          # daemon mode with HTTP API
```

### MCP Server

```json
{
  "mcpServers": {
    "nopea": { "command": "nopea", "args": ["mcp"] }
  }
}
```

Tools: `nopea_deploy`, `nopea_context`, `nopea_history`, `nopea_explain`

### HTTP API

```
GET  /health              → {"status": "ok"}
GET  /ready               → {"status": "ready"}
POST /api/deploy          → deploy manifests
GET  /api/context/:svc    → memory context
GET  /api/history/:svc    → deployment history
```

---

## Deployment Strategies

| Strategy | When Selected | How It Works |
|----------|---------------|--------------|
| **Direct** | Default, low-risk services | Apply all manifests immediately |
| **Canary** | Auto: failure patterns > 15% confidence | Gradual rollout (10→25→50→75→100%) |
| **Blue-Green** | Explicit or future auto-selection | Deploy to inactive slot, instant cutover |

Strategy auto-selection uses the KERTO graph:

```elixir
# Memory shows this service has failed before with high confidence
context = Memory.get_deploy_context("auth-service", "prod")
# failure_patterns: [%{type: :concurrent_deploy, confidence: 0.85}]
# → auto-selects :canary
```

---

## FALSE Protocol

Every deployment generates a structured occurrence for AI agents:

```
.nopea/
├── occurrence.json              # Cold path: AI/external consumers
└── occurrences/
    ├── 01ABC123.etf             # Warm path: fast BEAM reload
    └── ...
```

Occurrence types: `deploy.run.completed`, `deploy.run.failed`, `deploy.run.rolledback`

Each occurrence includes error blocks, reasoning (with memory context), history, and deploy data.

---

## Project Structure

```
nopea/
├── lib/nopea/
│   ├── application.ex          # OTP supervision tree
│   ├── deploy.ex               # Orchestration entry point
│   ├── deploy/
│   │   ├── spec.ex             # DeploySpec struct
│   │   ├── result.ex           # DeployResult struct
│   │   ├── worker.ex           # Per-deploy GenServer
│   │   └── supervisor.ex       # DynamicSupervisor
│   ├── strategy.ex             # Strategy behaviour
│   ├── strategy/
│   │   ├── direct.ex           # Immediate apply
│   │   ├── canary.ex           # Gradual rollout
│   │   └── blue_green.ex       # Slot-based cutover
│   ├── memory.ex               # KERTO graph GenServer
│   ├── memory/
│   │   ├── ingestor.ex         # Deploy events → graph ops
│   │   └── query.ex            # Context queries
│   ├── occurrence.ex           # FALSE Protocol generator
│   ├── mcp.ex                  # MCP server (JSON-RPC)
│   ├── api/router.ex           # HTTP API (Plug)
│   ├── sykli/target.ex         # SYKLI target integration
│   ├── cli.ex                  # Escript entry point
│   ├── k8s.ex                  # K8s API client
│   ├── k8s/behaviour.ex        # K8s behaviour (for Mox)
│   ├── applier.ex              # YAML parsing + server-side apply
│   ├── drift.ex                # Three-way drift detection
│   ├── cache.ex                # ETS deployment state
│   ├── ulid.ex                 # Monotonic ID generator
│   ├── events.ex               # CDEvents builder
│   ├── events/emitter.ex       # Async CDEvents emitter
│   ├── metrics.ex              # Telemetry metrics
│   ├── cluster.ex              # libcluster (optional)
│   ├── distributed_supervisor.ex  # Horde (optional)
│   └── distributed_registry.ex    # Horde (optional)
├── test/                       # 235 tests
├── config/
└── mix.exs
```

---

## Development

```bash
mix deps.get
mix test                     # 235 tests
mix compile --warnings-as-errors
mix format --check-formatted
mix credo
mix escript.build            # build CLI binary
```

---

## Tech Stack

| Component | Purpose |
|-----------|---------|
| **Elixir** | OTP supervision, GenServers, ETS |
| [kerto](https://github.com/yairfalse/kerto) | Knowledge graph (EWMA, content-addressed) |
| [k8s](https://hex.pm/packages/k8s) | Kubernetes client |
| [yaml_elixir](https://hex.pm/packages/yaml_elixir) | YAML parsing |
| [jason](https://hex.pm/packages/jason) | JSON encoding |
| [plug_cowboy](https://hex.pm/packages/plug_cowboy) | HTTP API |
| [req](https://hex.pm/packages/req) | HTTP client (CDEvents) |
| [libcluster](https://hex.pm/packages/libcluster) | BEAM clustering (optional) |
| [horde](https://hex.pm/packages/horde) | Distributed supervisor (optional) |
| [mox](https://hex.pm/packages/mox) | Test mocking |

---

## Naming

**Nopea** (Finnish: "fast") — Part of the [False Systems](https://github.com/yairfalse) toolchain.

---

## License

Apache 2.0

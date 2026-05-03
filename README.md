# Nopea

> Every deployment tool treats each deploy as the first deploy ever. Nopea remembers.

Nopea executes system changes with memory. Past outcomes shape how future changes run.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-1.14%2B-purple.svg)](https://elixir-lang.org)

---

## What Nopea is

Nopea is a memory-backed convergence controller for system changes.

It executes changes — today, Kubernetes deployments — and records what happened. Each subsequent execution is informed by what came before.

Deployments are the entry point. They are not the limit of what Nopea is meant to do.

---

## The shift

Traditional deploy tools are stateless. Each run starts from zero. The same failure can recur indefinitely because nothing in the loop remembers it happened.

Nopea is stateful by design:

- it accumulates outcomes from every execution
- it recognizes recurring conditions in the systems it operates on
- it adapts how it executes based on what it has seen before

The system is not just running changes. It is building operational knowledge of the systems it changes.

---

## How it works

```
intent → context → plan → execute → verify → learn
```

1. **intent** — a request to change a system arrives (deploy, rollback, promote)
2. **context** — Nopea consults what it has recorded about the target
3. **plan** — a strategy is selected, informed by context
4. **execute** — the change is applied
5. **verify** — convergence is confirmed
6. **learn** — the outcome is recorded; the next loop starts smarter

Every operation traverses every stage. There is no fast path that skips context or verification.

---

## Memory model

Nopea records what happens during every execution: what was changed, what was changing alongside it, and how it ended.

Over time, repeated conditions become recognizable patterns. A pattern might be:

> auth-service deployment failed when Redis was updated at the same time.

The next time auth-service is deployed under similar conditions, that pattern is part of the context for the new execution.

There is no separate memory product to install. Memory is part of Nopea.

---

## Usage

```bash
# Build
mix deps.get
mix escript.build

# Execute a change
nopea deploy -f manifests/ -s my-app -n default

# See what Nopea has accumulated about a service
nopea context my-app

# Past outcomes for this service
nopea history my-app
```

The second command shows what Nopea has recorded about `my-app`. The next deploy uses it. Every run after the first is informed by the runs before.

The same execution surface is reachable from CLI, MCP (for AI agents), and HTTP API — they all delegate to the same loop.

---

## Sykli integration

Sykli defines execution graphs: ordered, conditional flows of system changes.

Nopea executes the deployment-related nodes inside those graphs, with memory.

Sykli decides what should run, in what order, under what conditions. Nopea decides, given memory, how a particular change should be executed.

---

## What you get

- failures that have happened before influence how future executions are run
- strategy selection is grounded in your system's actual history, not a config default
- operational knowledge accumulates instead of being lost between runs

---

## Requirements

- Elixir 1.14+
- Kubernetes 1.22+ (server-side apply)

---

## License

Apache 2.0. Part of the [False Systems](https://github.com/false-systems) toolchain.

*Nopea — Finnish: "fast".*

# Nopea Oracle

Ground-truth test binary for Nopea. Connects to a live Nopea instance
and verifies external behavior through HTTP API and MCP protocol.

## Prerequisites

1. A running Nopea instance with HTTP API enabled:
   ```bash
   # In nopea root:
   NOPEA_ENABLE_ROUTER=true mix run --no-halt
   # or:
   mix escript.build && ./nopea serve
   ```

2. (Optional) Build escript for MCP tests:
   ```bash
   mix escript.build
   ```

## Running

```bash
cd eval/oracle
mix deps.get
mix test                          # All cases
mix test --exclude mcp            # Skip MCP (needs escript)
mix test --only auth_required     # Auth enforcement only
mix test --only auth_dev_mode     # Dev mode only
mix test test/case_061*           # Resilience only
```

## Configuration

| Env Var | Default | Description |
|---------|---------|-------------|
| `NOPEA_URL` | `http://localhost:4000` | Nopea HTTP API base URL |
| `NOPEA_API_KEY` | `nil` | API key (nil = dev mode) |
| `NOPEA_MCP_BINARY` | `../../nopea` | Path to escript binary |
| `NOPEA_SETTLE_MS` | `500` | Settlement time for async ops |

## Test Categories

| Range | Category | Count |
|-------|----------|-------|
| 001-005 | Health & Readiness | 5 |
| 006-015 | Authentication | 10 |
| 016-030 | Deploy Error Paths | 15 |
| 031-040 | Deploy Correctness | 10 |
| 041-050 | Memory & Context | 10 |
| 051-060 | Progressive Delivery | 10 |
| 061-075 | Resilience | 15 |
| 076-090 | MCP Protocol | 15 |
| 091-100 | Observability & Consistency | 10 |
| **Total** | | **100** |

## Design

The oracle is a **standalone project** — not part of the Nopea workspace.
It imports nothing from Nopea internals. It tests through public interfaces only.

Oracle failures are architectural signals. When a case fails, the fix is
often a design change (ADR), not a bug fix.

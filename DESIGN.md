# ALUMIINI Design Document

**ALUMIINI = Aluminum (Finnish) — Lightweight GitOps**

Part of **The Finnish Stack** by False Systems

---

## What Is ALUMIINI

GitOps controller for Kubernetes. Syncs Git repositories to clusters.

```
Git repo  ──watch──►  ALUMIINI  ──apply──►  Kubernetes
```

That's it. No Redis. No database. Just Elixir/BEAM.

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────┐
│                    ALUMIINI ARCHITECTURE                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   GitRepository CRD (K8s)                                       │
│   └── Defines: repo URL, branch, path, interval                 │
│                                                                 │
│   Elixir Core                                                   │
│   ├── Watcher: Monitors GitRepository CRDs                      │
│   ├── Supervisor: Manages Worker processes                      │
│   ├── Worker: One process per GitRepository                     │
│   ├── Cache: ETS tables (git state, manifests)                  │
│   └── Applier: Server-side apply to K8s                         │
│                                                                 │
│   Sync Triggers                                                 │
│   ├── Webhook: GitHub/GitLab push events (instant)              │
│   ├── Poll: Periodic git fetch (backup)                         │
│   ├── Reconcile: Drift detection (periodic)                     │
│   └── Startup: Recovery on restart                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why BEAM

### The Key Insight

**One GenServer per Git repository.**

```
┌─────────────────────────────────────────────────────────────────┐
│                    BEAM VM                                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                     │
│   │ Worker   │  │ Worker   │  │ Worker   │  ...                │
│   │ (repo-a) │  │ (repo-b) │  │ (repo-c) │                     │
│   └──────────┘  └──────────┘  └──────────┘                     │
│        │              │              │                          │
│        └──────────────┼──────────────┘                          │
│                       │                                         │
│               ┌───────▼───────┐                                 │
│               │  Supervisor   │                                 │
│               │ (DynamicSupervisor)                             │
│               └───────────────┘                                 │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │                      ETS Cache                           │  │
│   │  - Commit SHAs                                           │  │
│   │  - Parsed manifests                                      │  │
│   │  - Resource hashes                                       │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- Process crash = only that repo affected
- Supervisor auto-restarts failed workers
- No shared state corruption
- Natural rate limiting (one process = one sync at a time)
- No external dependencies (Redis, databases)

---

## Project Structure

```
alumiini/
├── lib/alumiini/
│   ├── application.ex     # OTP application
│   ├── cache.ex           # ETS cache
│   ├── supervisor.ex      # DynamicSupervisor
│   ├── worker.ex          # GenServer per repo
│   ├── watcher.ex         # K8s CRD watcher
│   ├── applier.ex         # K8s apply logic
│   └── webhook/
│       └── endpoint.ex    # HTTP webhook receiver
├── test/
└── mix.exs
```

---

## Custom Resource Definition

```yaml
apiVersion: alumiini.false.systems/v1alpha1
kind: GitRepository
metadata:
  name: my-app
  namespace: default
spec:
  url: https://github.com/org/my-app.git
  branch: main
  path: deploy/              # subdirectory (optional)
  interval: 5m               # poll interval
  timeout: 3m                # git/apply timeout
  targetNamespace: default   # where to apply
  secretRef:                 # auth (optional)
    name: git-credentials
status:
  lastSyncedCommit: abc123
  lastSyncTime: "2024-01-15T10:30:00Z"
  phase: Synced              # Synced | Syncing | Failed | Pending
```

---

## Core Modules

### Cache (ETS)

```elixir
defmodule Alumiini.Cache do
  @moduledoc """
  ETS tables for git state and manifests.

  Tables:
  - :commits    - {repo_name, commit_sha, timestamp}
  - :manifests  - {repo_name, commit_sha, resources}
  - :hashes     - {resource_uid, hash}
  """

  def get_last_commit(repo_name)
  def set_last_commit(repo_name, commit_sha)
  def get_manifests(repo_name, commit_sha)
  def cache_manifests(repo_name, commit_sha, resources)
end
```

### Supervisor (DynamicSupervisor)

```elixir
defmodule Alumiini.Supervisor do
  @moduledoc """
  Manages Worker processes.

  - Starts Worker when GitRepository created
  - Stops Worker when GitRepository deleted
  - Restarts failed Workers automatically
  """

  use DynamicSupervisor

  def start_worker(git_repository)
  def stop_worker(repo_name)
  def list_workers()
end
```

### Worker (GenServer)

```elixir
defmodule Alumiini.Worker do
  @moduledoc """
  One GenServer per GitRepository.

  Responsibilities:
  - Clone/fetch Git repository
  - Parse YAML manifests
  - Apply to Kubernetes
  - Update status
  - Emit CDEvents
  """

  use GenServer

  def sync_now(repo_name)
  def get_status(repo_name)

  # Callbacks
  def handle_info(:poll, state)
  def handle_info({:webhook, commit}, state)
  def handle_call(:sync_now, _from, state)
end
```

### Applier

```elixir
defmodule Alumiini.Applier do
  @moduledoc """
  Kubernetes apply operations.

  Features:
  - Server-side apply (K8s 1.22+)
  - Dry-run support
  - Prune orphaned resources
  """

  def apply(resources, opts \\ [])
  def dry_run(resources)
  def prune(namespace, label_selector, keep_resources)
end
```

### Watcher

```elixir
defmodule Alumiini.Watcher do
  @moduledoc """
  Watches GitRepository CRDs.

  Events:
  - ADDED: Start Worker
  - MODIFIED: Update Worker config
  - DELETED: Stop Worker
  """

  use GenServer
end
```

### Webhook.Endpoint

```elixir
defmodule Alumiini.Webhook.Endpoint do
  @moduledoc """
  HTTP endpoint for Git webhooks.

  Supported: GitHub, GitLab, Bitbucket
  """

  use Plug.Router

  post "/webhook/github" do
    # Verify signature
    # Extract commit
    # Send to Worker
  end
end
```

---

## Sync Triggers

| Trigger | When | Latency |
|---------|------|---------|
| Webhook | Git push event | ~1-2s |
| Poll | Timer interval (default 5m) | ≤5m |
| Reconcile | Drift detection (default 10m) | ≤10m |
| Startup | Process/pod restart | immediate |

**Priority:** Webhook > Poll > Reconcile > Startup

---

## Integration Points

### KULTA (Progressive Delivery)

```yaml
spec:
  rolloutRef:
    name: my-app-rollout    # Triggers KULTA instead of direct apply
```

When `rolloutRef` is set:
1. Apply non-Deployment resources normally
2. Update KULTA Rollout spec for Deployments
3. KULTA handles canary/blue-green

### RAUTA (Gateway API)

ALUMIINI applies HTTPRoute resources that RAUTA processes:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
spec:
  parentRefs:
    - name: rauta-gateway
```

### CDEvents

| Event | When |
|-------|------|
| `repository.fetched` | Git fetch complete |
| `deployment.started` | Apply begins |
| `deployment.finished` | Apply succeeds |
| `deployment.failed` | Apply fails |

---

## Error Handling

### Process Isolation

Worker crash affects only that repository:

```elixir
# Supervisor spec
%{
  id: repo_name,
  start: {Alumiini.Worker, :start_link, [git_repository]},
  restart: :permanent,
  shutdown: 5000
}
```

### Exponential Backoff

```elixir
defp schedule_retry(state) do
  delay = min(state.retry_count * 1000, 60_000)  # max 60s
  Process.send_after(self(), :retry_sync, delay)
  %{state | retry_count: state.retry_count + 1}
end
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Memory per repo | ~5MB |
| Webhook latency | <2s |
| Poll latency | <5s |
| Max concurrent repos | 100+ |

---

## Non-Goals

ALUMIINI will NOT:
- Support every Git provider edge case
- Include a web UI in v1
- Support Windows
- Replace enterprise GitOps features (RBAC, SSO, audit logs)

---

## Success Criteria

1. **Works**: Sync Git → K8s reliably
2. **Fast**: Sub-second webhook response
3. **Simple**: <5K lines of Elixir
4. **Stable**: Process isolation prevents cascading failures
5. **Observable**: CDEvents for pipeline visibility

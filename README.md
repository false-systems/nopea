# alumiini

**GitOps for Kubernetes. No Redis. No database. Just BEAM.**

```yaml
apiVersion: alumiini.false.systems/v1alpha1
kind: GitRepository
metadata:
  name: my-app
spec:
  url: https://github.com/org/my-app.git
  branch: main
  path: deploy/
  interval: 5m
```

Apply a GitRepository. ALUMIINI syncs it to your cluster.

---

## Why

GitOps controllers need to manage many repositories concurrently. The BEAM VM provides:

- **Process isolation** - One GenServer per repo, crash isolation
- **Supervision** - Automatic restart on failure
- **ETS** - In-memory caching without Redis
- **Lightweight** - ~5MB per repository

No external dependencies. No database. Just Elixir.

---

## How It Works

```
Git repo  ──watch──►  ALUMIINI  ──apply──►  Kubernetes
```

1. Create a `GitRepository` resource
2. ALUMIINI spawns a Worker process for it
3. Worker clones/fetches the repo
4. Worker applies manifests to the cluster
5. Repeat on webhook or timer

---

## Install

```bash
# Coming soon
kubectl apply -f https://alumiini.false.systems/install.yaml
```

For now, build from source:

```bash
cd alumiini
mix deps.get
mix release
```

---

## GitRepository CRD

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
  targetNamespace: default   # where to apply

  # Auth (optional)
  secretRef:
    name: git-credentials

  # Progressive delivery (optional)
  rolloutRef:
    name: my-app-rollout     # triggers KULTA
status:
  lastSyncedCommit: abc123
  lastSyncTime: "2024-01-15T10:30:00Z"
  phase: Synced
```

---

## Sync Triggers

| Trigger | When | Latency |
|---------|------|---------|
| Webhook | Git push | ~1-2s |
| Poll | Timer | configurable |
| Drift | K8s change | ~10m |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    BEAM VM                                │
│                                                          │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│   │ Worker   │  │ Worker   │  │ Worker   │  ...         │
│   │ (repo-a) │  │ (repo-b) │  │ (repo-c) │              │
│   └──────────┘  └──────────┘  └──────────┘              │
│        │              │              │                   │
│        └──────────────┼──────────────┘                   │
│                       │                                  │
│               ┌───────▼───────┐                          │
│               │  Supervisor   │                          │
│               └───────────────┘                          │
│                                                          │
│   ┌────────────────────────────────────────────────┐    │
│   │                 ETS Cache                       │    │
│   └────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

Each repository gets its own process. Crash isolation by design.

---

## The Finnish Stack

Part of **The Finnish Stack** by False Systems:

| Project | Purpose | Language |
|---------|---------|----------|
| **SYKLI** | CI in your language | Elixir core |
| **ALUMIINI** | GitOps | Elixir |
| **KULTA** | Progressive delivery | Rust |
| **RAUTA** | Gateway API | Rust |
| **SEPPO** | K8s testing | Rust |

---

## Name

*Alumiini* — Finnish for "aluminum". Lightweight metal.

---

## License

Apache-2.0

defmodule Nopea.Cluster do
  @moduledoc """
  Cluster topology configuration using libcluster.

  Provides automatic node discovery for BEAM clustering in Kubernetes.
  When nodes join the cluster, Horde's Registry and DynamicSupervisor
  automatically sync their state via CRDTs.

  ## Configuration

  Set these environment variables or application config:

      # Enable clustering
      config :nopea, cluster_enabled: true

      # Strategy: :kubernetes_dns (production) or :gossip (development)
      config :nopea, cluster_strategy: :kubernetes_dns

      # For Kubernetes DNS strategy
      config :nopea, cluster_service: "nopea-headless"
      config :nopea, cluster_app_name: "nopea"
      config :nopea, pod_namespace: "nopea-system"

  ## Kubernetes Setup

  For K8s clustering to work, you need a headless service:

      apiVersion: v1
      kind: Service
      metadata:
        name: nopea-headless
      spec:
        clusterIP: None
        selector:
          app: nopea
        ports:
          - port: 4369  # EPMD
          - port: 9000  # Distributed Erlang

  And pods must have proper ERLANG_COOKIE and node naming.
  """

  @doc """
  Returns child spec for the cluster topology supervisor.

  Add this to your application supervision tree:

      children = [
        Nopea.Cluster.child_spec([])
      ]

  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Nopea.Cluster.Supervisor,
      start: {Nopea.Cluster.Supervisor, :start_link, [topology(), opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns whether clustering is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:nopea, :cluster_enabled, false)
  end

  @doc """
  Returns the cluster topology configuration.

  Reads from application config to determine which strategy to use.
  """
  @spec topology() :: keyword()
  def topology do
    if enabled?() do
      strategy = Application.get_env(:nopea, :cluster_strategy, :kubernetes_dns)
      build_topology(strategy)
    else
      []
    end
  end

  defp build_topology(:kubernetes_dns) do
    service = Application.get_env(:nopea, :cluster_service, "nopea-headless")
    app_name = Application.get_env(:nopea, :cluster_app_name, "nopea")
    namespace = Application.get_env(:nopea, :pod_namespace, "default")
    polling_interval = Application.get_env(:nopea, :cluster_polling_interval, 5_000)

    [
      k8s: [
        # libcluster strategy for K8s DNS discovery
        strategy: Elixir.Cluster.Strategy.Kubernetes.DNS,
        config: [
          service: service,
          application_name: app_name,
          namespace: namespace,
          polling_interval: polling_interval
        ]
      ]
    ]
  end

  defp build_topology(:gossip) do
    port = Application.get_env(:nopea, :cluster_gossip_port, 45_892)
    secret = Application.get_env(:nopea, :cluster_gossip_secret, "nopea-dev-secret")

    [
      gossip: [
        # libcluster strategy for UDP multicast gossip
        strategy: Elixir.Cluster.Strategy.Gossip,
        config: [
          port: port,
          if_addr: "0.0.0.0",
          multicast_if: "0.0.0.0",
          multicast_addr: "230.1.1.1",
          multicast_ttl: 1,
          secret: secret
        ]
      ]
    ]
  end

  defp build_topology(:epmd) do
    # Useful for local development with named nodes
    hosts = Application.get_env(:nopea, :cluster_hosts, [])

    [
      epmd: [
        # libcluster strategy for EPMD-based discovery
        strategy: Elixir.Cluster.Strategy.Epmd,
        config: [
          hosts: hosts
        ]
      ]
    ]
  end

  defp build_topology(_unknown) do
    # Default to disabled
    []
  end
end

defmodule Nopea.Cluster.Supervisor do
  @moduledoc """
  Supervisor for libcluster topology.
  """

  use Supervisor

  def start_link(topology, opts \\ []) do
    Supervisor.start_link(__MODULE__, topology, opts)
  end

  @impl true
  def init(topology) do
    children =
      if topology != [] do
        [{Cluster.Supervisor, [topology, [name: Nopea.ClusterTopology]]}]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

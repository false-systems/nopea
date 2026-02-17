defmodule Nopea.Application do
  @moduledoc """
  NOPEA OTP Application.

  Supervision tree:
  - Nopea.ULID (monotonic ID generator)
  - Nopea.Events.Emitter (CDEvents HTTP emitter, optional)
  - Nopea.Memory (knowledge graph)
  - Nopea.Cache (ETS storage)
  - Nopea.Registry or Nopea.DistributedRegistry (cluster mode)
  - Nopea.ServiceAgent.Supervisor (DynamicSupervisor for per-service agents)
  - Nopea.Deploy.Supervisor (DynamicSupervisor for deploy workers)
  - Nopea.Cluster (libcluster, optional)
  - Nopea.DistributedSupervisor (Horde, optional)
  - Nopea.API.Router (HTTP API, optional)
  """

  use Application

  @impl true
  def start(_type, _args) do
    cluster_enabled = Application.get_env(:nopea, :cluster_enabled, false)

    children =
      [Nopea.ULID]
      |> add_metrics_child()
      |> add_cdevents_child()
      |> add_cache_child()
      |> add_memory_child()
      |> add_cluster_child(cluster_enabled)
      |> add_registry_child(cluster_enabled)
      |> add_service_agent_child()
      |> add_deploy_supervisor_child(cluster_enabled)
      |> add_router_child()

    opts = [strategy: :one_for_one, name: Nopea.AppSupervisor]
    Supervisor.start_link(children, opts)
  end

  defp add_metrics_child(children) do
    if Application.get_env(:nopea, :enable_metrics, true) do
      children ++
        [
          {TelemetryMetricsPrometheus.Core,
           metrics: Nopea.Metrics.metrics(), name: :nopea_metrics}
        ]
    else
      children
    end
  end

  defp add_cdevents_child(children) do
    case Application.get_env(:nopea, :cdevents_endpoint) do
      nil -> children
      endpoint -> children ++ [{Nopea.Events.Emitter, endpoint: endpoint}]
    end
  end

  defp add_memory_child(children) do
    if Application.get_env(:nopea, :enable_memory, true),
      do: children ++ [Nopea.Memory],
      else: children
  end

  defp add_cache_child(children) do
    if Application.get_env(:nopea, :enable_cache, true),
      do: children ++ [Nopea.Cache],
      else: children
  end

  defp add_cluster_child(children, false), do: children
  defp add_cluster_child(children, true), do: children ++ [Nopea.Cluster.child_spec([])]

  defp add_registry_child(children, cluster_enabled) do
    if Application.get_env(:nopea, :enable_deploy_supervisor, true) do
      if cluster_enabled do
        children ++ [Nopea.DistributedRegistry]
      else
        children ++ [{Registry, keys: :unique, name: Nopea.Registry}]
      end
    else
      children
    end
  end

  defp add_service_agent_child(children) do
    if Application.get_env(:nopea, :enable_deploy_supervisor, true),
      do: children ++ [Nopea.ServiceAgent.Supervisor],
      else: children
  end

  defp add_deploy_supervisor_child(children, cluster_enabled) do
    if Application.get_env(:nopea, :enable_deploy_supervisor, true) do
      if cluster_enabled do
        children ++ [Nopea.DistributedSupervisor]
      else
        children ++ [Nopea.Deploy.Supervisor]
      end
    else
      children
    end
  end

  defp add_router_child(children) do
    if Application.get_env(:nopea, :enable_router, false),
      do: children ++ [Nopea.API.Router],
      else: children
  end
end

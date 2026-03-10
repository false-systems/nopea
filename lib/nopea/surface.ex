defmodule Nopea.Surface do
  @moduledoc """
  Shared domain logic backing CLI, MCP, and HTTP surfaces.

  Every user-facing interface delegates here. This guarantees
  consistent behaviour and graceful degradation when optional
  subsystems (Memory, Cache, Registry) are not running.
  """

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def status(service) do
    cond do
      Process.whereis(Nopea.ServiceAgent.Supervisor) != nil ->
        Nopea.ServiceAgent.status(service)

      Nopea.Cache.available?() ->
        Nopea.Cache.get_service_state(service)

      true ->
        {:error, :unavailable}
    end
  end

  @spec context(String.t(), String.t()) :: map()
  def context(service, namespace \\ "default") do
    if Process.whereis(Nopea.Memory) do
      Nopea.Memory.get_deploy_context(service, namespace)
    else
      %{known: false, message: "Memory not available"}
    end
  end

  @spec history(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def history(service) do
    if Nopea.Cache.available?() do
      case Nopea.Cache.get_service_state(service) do
        {:ok, state} -> {:ok, %{service: service, state: state}}
        {:error, :not_found} -> {:error, :not_found}
      end
    else
      {:error, :unavailable}
    end
  end

  @spec explain(String.t(), String.t()) :: String.t()
  def explain(service, namespace \\ "default") do
    if Process.whereis(Nopea.Memory) do
      context = Nopea.Memory.get_deploy_context(service, namespace)
      explain_strategy(service, namespace, context)
    else
      "Memory not available. Would use direct strategy by default."
    end
  end

  @spec health() :: map()
  def health do
    agents =
      if Process.whereis(Nopea.ServiceAgent.Supervisor) != nil do
        Nopea.ServiceAgent.health()
      else
        []
      end

    memory =
      if Process.whereis(Nopea.Memory) do
        %{
          nodes: Nopea.Memory.node_count(),
          relationships: Nopea.Memory.relationship_count()
        }
      else
        %{status: :not_running}
      end

    %{agents: agents, agent_count: length(agents), memory: memory}
  end

  @spec services() :: [String.t()]
  def services do
    if Nopea.Cache.available?() do
      Nopea.Cache.list_services()
    else
      []
    end
  end

  @spec promote(String.t()) :: {:ok, Nopea.Progressive.Rollout.t()} | {:error, term()}
  def promote(deploy_id) do
    Nopea.Progressive.Monitor.promote(deploy_id)
  end

  @spec rollback(String.t()) :: {:ok, Nopea.Progressive.Rollout.t()} | {:error, term()}
  def rollback(deploy_id) do
    Nopea.Progressive.Monitor.rollback(deploy_id)
  end

  @spec rollout_status(String.t()) :: {:ok, Nopea.Progressive.Rollout.t()} | {:error, :not_found}
  def rollout_status(deploy_id) do
    Nopea.Progressive.Monitor.status(deploy_id)
  end

  # Private

  defp explain_strategy(service, namespace, context) do
    cond do
      not context.known ->
        "No deployment history for #{service}/#{namespace}. " <>
          "Would use direct strategy (default for unknown services)."

      Enum.any?(context.failure_patterns, fn p -> p.confidence > 0.15 end) ->
        patterns =
          Enum.map_join(context.failure_patterns, ", ", fn p ->
            "#{p.error} (confidence: #{Float.round(p.confidence, 2)})"
          end)

        "Failure patterns detected for #{service}/#{namespace}: #{patterns}. " <>
          "Use canary or blue_green strategy — Kulta will handle progressive delivery."

      true ->
        "Would use direct strategy for #{service}/#{namespace}. " <>
          "No significant failure patterns detected. Service is known and stable."
    end
  end
end

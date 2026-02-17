defmodule Nopea.Memory.Query do
  @moduledoc """
  Queries the KERTO knowledge graph for deployment context.

  Provides context-aware information about services:
  - Failure rates and patterns
  - Dependencies between services
  - Recommendations based on historical data
  """

  alias Kerto.Graph.{Graph, Identity}

  @spec deploy_context(Graph.t(), String.t(), String.t()) :: map()
  def deploy_context(graph, service, namespace) do
    service_id = Identity.compute_id(:concept, service)

    %{
      service: service,
      namespace: namespace,
      known: Graph.get_node(graph, service_id) != :error,
      failure_patterns: failure_patterns(graph, service_id),
      dependencies: dependencies(graph, service_id),
      recommendations: recommendations(graph, service_id)
    }
  end

  @spec failure_patterns(Graph.t(), String.t()) :: [map()]
  def failure_patterns(graph, service_id) do
    graph
    |> Graph.neighbors(service_id, :outgoing)
    |> Enum.filter(fn rel -> rel.relation == :breaks end)
    |> Enum.map(fn rel ->
      case Graph.get_node(graph, rel.target) do
        {:ok, node} ->
          %{
            error: node.name,
            confidence: rel.weight,
            observations: rel.observations,
            evidence: rel.evidence
          }

        :error ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.confidence, :desc)
  end

  @spec dependencies(Graph.t(), String.t()) :: [map()]
  def dependencies(graph, service_id) do
    graph
    |> Graph.neighbors(service_id, :outgoing)
    |> Enum.filter(fn rel -> rel.relation == :depends_on end)
    |> Enum.map(fn rel ->
      case Graph.get_node(graph, rel.target) do
        {:ok, node} ->
          %{target: node.name, weight: rel.weight, observations: rel.observations}

        :error ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @spec recommendations(Graph.t(), String.t()) :: [String.t()]
  def recommendations(graph, service_id) do
    failures = failure_patterns(graph, service_id)

    high_risk =
      failures
      |> Enum.filter(fn f -> f.confidence > 0.7 and f.observations >= 2 end)
      |> Enum.map(fn f ->
        "High failure rate (#{Float.round(f.confidence, 2)}) for #{f.error} — seen #{f.observations} times. Consider canary deployment."
      end)

    high_risk
  end
end

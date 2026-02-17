defmodule Nopea.Memory.Ingestor do
  @moduledoc """
  Transforms deployment events into KERTO graph operations.

  Converts deploy results (success/failure/rollback) into
  graph nodes and relationships that build deployment memory.
  """

  alias Kerto.Graph.Graph

  @spec ingest(Graph.t(), map()) :: Graph.t()
  def ingest(graph, %{service: service, namespace: namespace, status: status} = result) do
    ulid = Nopea.Helpers.generate_ulid()
    confidence = status_confidence(status)

    # Upsert service node
    {graph, _node} = Graph.upsert_node(graph, :concept, service, confidence, ulid)

    # Upsert namespace node
    {graph, _node} = Graph.upsert_node(graph, :concept, "namespace:#{namespace}", 0.5, ulid)

    # Service → deployed_to → namespace
    service_id = Kerto.Graph.Identity.compute_id(:concept, service)
    ns_id = Kerto.Graph.Identity.compute_id(:concept, "namespace:#{namespace}")

    {graph, _rel} =
      Graph.upsert_relationship(
        graph,
        service_id,
        :deployed_to,
        ns_id,
        confidence,
        ulid,
        "deploy #{status} at #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      )

    # Record failure patterns
    graph = maybe_record_failure(graph, result, ulid)

    # Record dependencies
    graph = maybe_record_dependencies(graph, result, ulid)

    graph
  end

  def ingest(graph, _unknown), do: graph

  defp maybe_record_failure(graph, %{status: :failed, error: error, service: service}, ulid)
       when not is_nil(error) do
    error_name = normalize_error_name(error)

    {graph, _node} = Graph.upsert_node(graph, :error, error_name, 0.8, ulid)

    service_id = Kerto.Graph.Identity.compute_id(:concept, service)
    error_id = Kerto.Graph.Identity.compute_id(:error, error_name)

    {graph, _rel} =
      Graph.upsert_relationship(
        graph,
        service_id,
        :breaks,
        error_id,
        0.8,
        ulid,
        "deploy failed: #{inspect(error)}"
      )

    graph
  end

  defp maybe_record_failure(graph, _result, _ulid), do: graph

  defp maybe_record_dependencies(graph, %{concurrent_deploys: [_ | _] = deploys}, ulid) do
    Enum.reduce(deploys, graph, fn other_service, g ->
      {g, _node} = Graph.upsert_node(g, :concept, other_service, 0.5, ulid)
      g
    end)
  end

  defp maybe_record_dependencies(graph, _result, _ulid), do: graph

  defp status_confidence(:completed), do: 0.9
  defp status_confidence(:failed), do: 0.8
  defp status_confidence(:rolledback), do: 0.7
  defp status_confidence(_), do: 0.5

  defp normalize_error_name({type, _msg}) when is_atom(type), do: Atom.to_string(type)
  defp normalize_error_name(error) when is_binary(error), do: error
  defp normalize_error_name(error), do: inspect(error)
end

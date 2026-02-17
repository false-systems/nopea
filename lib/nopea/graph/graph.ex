defmodule Nopea.Graph.Graph do
  @moduledoc """
  The Knowledge Graph — set of all Knowledge Nodes and Relationships.

  Pure data structure. No side effects, no persistence, no ETS.
  """

  alias Nopea.Graph.{Node, Relationship, Identity}

  defstruct nodes: %{}, relationships: %{}

  @type t :: %__MODULE__{
          nodes: %{String.t() => Node.t()},
          relationships: %{relationship_key() => Relationship.t()}
        }

  @type relationship_key :: {String.t(), atom(), String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec node_count(t()) :: non_neg_integer()
  def node_count(%__MODULE__{nodes: nodes}), do: map_size(nodes)

  @spec relationship_count(t()) :: non_neg_integer()
  def relationship_count(%__MODULE__{relationships: rels}), do: map_size(rels)

  @spec upsert_node(t(), atom(), String.t(), float(), String.t()) :: {t(), Node.t()}
  def upsert_node(%__MODULE__{} = graph, kind, name, confidence, ulid) do
    id = Identity.compute_id(kind, name)

    case Map.get(graph.nodes, id) do
      nil ->
        node = Node.new(kind, name, ulid)
        {%{graph | nodes: Map.put(graph.nodes, id, node)}, node}

      existing ->
        node = Node.observe(existing, confidence, ulid)
        {%{graph | nodes: Map.put(graph.nodes, id, node)}, node}
    end
  end

  @spec upsert_relationship(t(), String.t(), atom(), String.t(), float(), String.t(), String.t()) ::
          {t(), Relationship.t()}
  def upsert_relationship(
        %__MODULE__{} = graph,
        source_id,
        relation,
        target_id,
        confidence,
        ulid,
        evidence_text
      ) do
    key = {source_id, relation, target_id}

    case Map.get(graph.relationships, key) do
      nil ->
        rel = Relationship.new(source_id, relation, target_id, ulid, evidence_text)
        {%{graph | relationships: Map.put(graph.relationships, key, rel)}, rel}

      existing ->
        rel = Relationship.reinforce(existing, confidence, ulid, evidence_text)
        {%{graph | relationships: Map.put(graph.relationships, key, rel)}, rel}
    end
  end

  @spec get_node(t(), String.t()) :: {:ok, Node.t()} | :error
  def get_node(%__MODULE__{} = graph, id) do
    case Map.get(graph.nodes, id) do
      nil -> :error
      node -> {:ok, node}
    end
  end

  @spec neighbors(t(), String.t(), :outgoing | :incoming) :: [Relationship.t()]
  def neighbors(%__MODULE__{} = graph, node_id, direction) do
    graph.relationships
    |> Map.values()
    |> Enum.filter(fn rel ->
      case direction do
        :outgoing -> rel.source == node_id
        :incoming -> rel.target == node_id
      end
    end)
  end

  @spec subgraph(t(), String.t(), keyword()) :: {[Node.t()], [Relationship.t()]}
  def subgraph(%__MODULE__{} = graph, root_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)
    min_weight = Keyword.get(opts, :min_weight, 0.0)

    case Map.get(graph.nodes, root_id) do
      nil ->
        {[], []}

      _root ->
        {visited, collected_rels} =
          bfs(graph, [{root_id, 0}], MapSet.new([root_id]), [], depth, min_weight)

        nodes =
          visited
          |> MapSet.to_list()
          |> Enum.map(&Map.fetch!(graph.nodes, &1))

        {nodes, collected_rels}
    end
  end

  defp bfs(_graph, [], visited, rels, _max_depth, _min_weight), do: {visited, rels}

  defp bfs(graph, [{node_id, current_depth} | queue], visited, rels, max_depth, min_weight) do
    if current_depth >= max_depth do
      bfs(graph, queue, visited, rels, max_depth, min_weight)
    else
      adjacent =
        graph.relationships
        |> Map.values()
        |> Enum.filter(fn rel ->
          (rel.source == node_id or rel.target == node_id) and rel.weight >= min_weight
        end)

      new_rels = adjacent -- rels
      rels = Enum.uniq(rels ++ new_rels)

      neighbor_ids =
        adjacent
        |> Enum.flat_map(fn rel ->
          cond do
            rel.source == node_id -> [rel.target]
            rel.target == node_id -> [rel.source]
          end
        end)
        |> Enum.reject(&MapSet.member?(visited, &1))
        |> Enum.uniq()

      visited = Enum.reduce(neighbor_ids, visited, &MapSet.put(&2, &1))
      new_queue = Enum.map(neighbor_ids, &{&1, current_depth + 1})

      bfs(graph, queue ++ new_queue, visited, rels, max_depth, min_weight)
    end
  end

  @spec decay_all(t(), float()) :: t()
  def decay_all(%__MODULE__{} = graph, factor) when is_float(factor) do
    nodes =
      graph.nodes
      |> Map.new(fn {id, node} -> {id, Node.decay(node, factor)} end)

    relationships =
      graph.relationships
      |> Map.new(fn {key, rel} -> {key, Relationship.decay(rel, factor)} end)
      |> Enum.reject(fn {_key, rel} -> Relationship.dead?(rel) end)
      |> Map.new()

    # Prune dead nodes with no relationships
    connected_node_ids =
      relationships
      |> Map.values()
      |> Enum.flat_map(fn rel -> [rel.source, rel.target] end)
      |> MapSet.new()

    nodes =
      nodes
      |> Enum.reject(fn {id, node} ->
        Node.dead?(node) and not MapSet.member?(connected_node_ids, id)
      end)
      |> Map.new()

    %{graph | nodes: nodes, relationships: relationships}
  end
end

defmodule Nopea.Graph.Node do
  @moduledoc """
  Knowledge Node — the primary entity in the graph.

  Content-addressed identity: same file mentioned by 20 agents = one node.
  Relevance decays over time, reinforced by new observations.
  """

  alias Nopea.Graph.{EWMA, Identity, NodeKind}

  @enforce_keys [:id, :name, :kind, :relevance, :observations, :first_seen, :last_seen]
  defstruct [:id, :name, :kind, :relevance, :observations, :first_seen, :last_seen]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          kind: atom(),
          relevance: float(),
          observations: non_neg_integer(),
          first_seen: String.t(),
          last_seen: String.t()
        }

  @node_death_threshold 0.01

  @spec new(atom(), String.t(), String.t()) :: t()
  def new(kind, name, ulid)
      when is_atom(kind) and is_binary(name) and is_binary(ulid) do
    true = NodeKind.valid?(kind)
    canonical = Identity.canonicalize_name(kind, name)

    %__MODULE__{
      id: Identity.compute_id(kind, name),
      name: canonical,
      kind: kind,
      relevance: 0.5,
      observations: 1,
      first_seen: ulid,
      last_seen: ulid
    }
  end

  @spec observe(t(), float(), String.t()) :: t()
  def observe(%__MODULE__{} = node, confidence, ulid)
      when is_float(confidence) and is_binary(ulid) do
    %{
      node
      | relevance: EWMA.update(node.relevance, confidence),
        observations: node.observations + 1,
        last_seen: ulid
    }
  end

  @spec decay(t(), float()) :: t()
  def decay(%__MODULE__{} = node, factor \\ 0.95) do
    %{node | relevance: EWMA.decay(node.relevance, factor)}
  end

  @spec dead?(t()) :: boolean()
  def dead?(%__MODULE__{} = node) do
    EWMA.dead?(node.relevance, @node_death_threshold)
  end
end

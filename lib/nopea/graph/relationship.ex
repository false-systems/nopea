defmodule Nopea.Graph.Relationship do
  @moduledoc """
  A weighted, directional connection between two Knowledge Nodes.

  Composite identity: {source_id, relation, target_id}.
  Same relationship from multiple sources reinforces weight, doesn't duplicate.
  Evidence accumulates — every observation appends, never overwrites.
  """

  alias Nopea.Graph.{EWMA, RelationType}

  @enforce_keys [
    :source,
    :target,
    :relation,
    :weight,
    :observations,
    :first_seen,
    :last_seen,
    :evidence
  ]
  defstruct [
    :source,
    :target,
    :relation,
    :weight,
    :observations,
    :first_seen,
    :last_seen,
    :evidence
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          target: String.t(),
          relation: atom(),
          weight: float(),
          observations: non_neg_integer(),
          first_seen: String.t(),
          last_seen: String.t(),
          evidence: [String.t()]
        }

  @rel_death_threshold 0.05

  @spec new(String.t(), atom(), String.t(), String.t(), String.t() | nil) :: t()
  def new(source, relation, target, ulid, evidence_text \\ nil)
      when is_binary(source) and is_atom(relation) and is_binary(target) and is_binary(ulid) do
    true = RelationType.valid?(relation)

    %__MODULE__{
      source: source,
      target: target,
      relation: relation,
      weight: 0.5,
      observations: 1,
      first_seen: ulid,
      last_seen: ulid,
      evidence: if(evidence_text, do: [evidence_text], else: [])
    }
  end

  @spec reinforce(t(), float(), String.t(), String.t()) :: t()
  def reinforce(%__MODULE__{} = rel, confidence, ulid, evidence_text)
      when is_float(confidence) and is_binary(ulid) and is_binary(evidence_text) do
    %{
      rel
      | weight: EWMA.update(rel.weight, confidence),
        observations: rel.observations + 1,
        last_seen: ulid,
        evidence: rel.evidence ++ [evidence_text]
    }
  end

  @spec decay(t(), float()) :: t()
  def decay(%__MODULE__{} = rel, factor \\ 0.95) do
    %{rel | weight: EWMA.decay(rel.weight, factor)}
  end

  @spec dead?(t()) :: boolean()
  def dead?(%__MODULE__{} = rel) do
    EWMA.dead?(rel.weight, @rel_death_threshold)
  end
end

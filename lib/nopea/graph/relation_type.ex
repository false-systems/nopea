defmodule Nopea.Graph.RelationType do
  @moduledoc """
  Classification of a Relationship between Knowledge Nodes.

  Value object — immutable, equality by value.
  """

  @types [
    :breaks,
    :caused_by,
    :triggers,
    :depends_on,
    :deployed_to,
    :part_of,
    :learned,
    :decided,
    :tried_failed,
    :often_changes_with
  ]

  @spec all() :: [atom()]
  def all, do: @types

  @spec valid?(term()) :: boolean()
  def valid?(type) when type in @types, do: true
  def valid?(_), do: false
end

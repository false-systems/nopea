defmodule Nopea.Graph.RelationType do
  @moduledoc """
  Classification of a Relationship between Knowledge Nodes.

  Value object — immutable, equality by value.
  """

  @types [
    :breaks,
    :deployed_to
  ]

  @spec valid?(term()) :: boolean()
  def valid?(type) when type in @types, do: true
  def valid?(_), do: false
end

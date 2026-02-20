defmodule Nopea.Graph.NodeKind do
  @moduledoc """
  Classification of a Knowledge Node.

  Value object — immutable, equality by value.
  """

  @kinds [:error, :concept]

  @spec valid?(term()) :: boolean()
  def valid?(kind) when kind in @kinds, do: true
  def valid?(_), do: false
end

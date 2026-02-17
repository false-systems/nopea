defmodule Nopea.Graph.NodeKind do
  @moduledoc """
  Classification of a Knowledge Node.

  Value object — immutable, equality by value.
  """

  @kinds [:file, :module, :pattern, :decision, :error, :concept]

  @spec all() :: [atom()]
  def all, do: @kinds

  @spec valid?(term()) :: boolean()
  def valid?(kind) when kind in @kinds, do: true
  def valid?(_), do: false
end

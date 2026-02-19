defmodule Nopea.Graph.Identity do
  @moduledoc """
  Content-addressed identity for Knowledge Nodes.

  id = blake2b(kind + canonical_name)

  Same file mentioned by 20 agents in 20 sessions = one node. Always.
  Pure value object. No side effects, no dependencies.
  """

  @hash_size 16

  @doc """
  Compute a content-addressed ID from kind and name.

  Canonicalizes the name first, then hashes with BLAKE2b.
  """
  @spec compute_id(atom(), String.t()) :: String.t()
  def compute_id(kind, name) when is_atom(kind) and is_binary(name) do
    canonical = canonicalize_name(kind, name)
    input = "#{kind}:#{canonical}"

    :crypto.hash(:blake2b, input)
    |> binary_part(0, @hash_size)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Canonicalize a name based on its kind.

  - `:error` — lowercase
  - `:concept` — preserve as-is
  """
  @spec canonicalize_name(atom(), String.t()) :: String.t()
  def canonicalize_name(:error, name), do: String.downcase(name)
  def canonicalize_name(_kind, name), do: name
end

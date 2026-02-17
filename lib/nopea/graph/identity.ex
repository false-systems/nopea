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

  - `:file` — normalize path separators, resolve `..`, strip `./` and trailing `/`
  - `:pattern`, `:error` — lowercase
  - `:module`, `:decision`, `:concept` — preserve as-is
  """
  @spec canonicalize_name(atom(), String.t()) :: String.t()
  def canonicalize_name(:file, name) do
    name
    |> String.split("/")
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [_ | rest] -> rest
      "..", [] -> []
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
    |> String.trim_trailing("/")
  end

  def canonicalize_name(:pattern, name), do: String.downcase(name)
  def canonicalize_name(:error, name), do: String.downcase(name)
  def canonicalize_name(_kind, name), do: name
end

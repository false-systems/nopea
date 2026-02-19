defmodule Nopea.Helpers do
  @moduledoc """
  Shared utility functions used across multiple Nopea modules.
  """

  @doc """
  Generates a monotonic ULID, falling back to random if the ULID Agent isn't running.
  """
  @spec generate_ulid() :: String.t()
  def generate_ulid do
    case Process.whereis(Nopea.ULID) do
      nil -> Nopea.ULID.generate_random()
      _pid -> Nopea.ULID.generate()
    end
  end

  @doc """
  Parses a strategy string into an atom. Returns nil for unrecognized strategies.
  """
  @spec parse_strategy(String.t() | nil) :: atom() | nil
  def parse_strategy("direct"), do: :direct
  def parse_strategy("canary"), do: :canary
  def parse_strategy("blue_green"), do: :blue_green
  def parse_strategy("blue-green"), do: :blue_green
  def parse_strategy(_), do: nil

  @doc """
  Serializes a Deploy.Result struct into a summary map for API/MCP responses.
  """
  @spec serialize_deploy_result(Nopea.Deploy.Result.t()) :: map()
  def serialize_deploy_result(result) do
    %{
      deploy_id: result.deploy_id,
      status: result.status,
      service: result.service,
      namespace: result.namespace,
      strategy: result.strategy,
      duration_ms: result.duration_ms,
      manifest_count: result.manifest_count
    }
  end
end

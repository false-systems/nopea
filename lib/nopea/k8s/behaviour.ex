defmodule Nopea.K8s.Behaviour do
  @moduledoc """
  Behaviour for K8s operations.

  Allows mocking K8s calls in tests.
  """

  @callback conn() :: {:ok, K8s.Conn.t()} | {:error, term()}

  @callback get_resource(
              api_version :: String.t(),
              kind :: String.t(),
              name :: String.t(),
              namespace :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @callback apply_manifests(manifests :: [map()], target_namespace :: String.t() | nil) ::
              {:ok, [map()]} | {:error, term()}

  @callback apply_manifest(manifest :: map(), target_namespace :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @callback delete_resource(
              api_version :: String.t(),
              kind :: String.t(),
              name :: String.t(),
              namespace :: String.t()
            ) :: :ok | {:error, term()}
end

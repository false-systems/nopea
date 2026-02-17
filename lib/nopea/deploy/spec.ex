defmodule Nopea.Deploy.Spec do
  @moduledoc """
  Deployment specification struct.

  Defines what to deploy, where, and how.
  """

  @type t :: %__MODULE__{
          service: String.t(),
          namespace: String.t(),
          manifests: [map()],
          strategy: atom() | nil,
          manifest_path: String.t() | nil,
          timeout_ms: pos_integer(),
          options: keyword()
        }

  @enforce_keys [:service, :namespace, :manifests]
  defstruct [
    :service,
    :namespace,
    :manifests,
    :strategy,
    :manifest_path,
    timeout_ms: 120_000,
    options: []
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      service: Map.fetch!(map, :service),
      namespace: Map.get(map, :namespace, "default"),
      manifests: Map.get(map, :manifests, []),
      strategy: Map.get(map, :strategy),
      manifest_path: Map.get(map, :manifest_path),
      timeout_ms: Map.get(map, :timeout_ms, 120_000)
    }
  end

  @spec from_path(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_path(path, service, namespace, opts \\ []) do
    case Nopea.Applier.read_manifests_from_path(path) do
      {:ok, manifests} ->
        {:ok,
         %__MODULE__{
           service: service,
           namespace: namespace,
           manifests: manifests,
           strategy: Keyword.get(opts, :strategy),
           manifest_path: path,
           timeout_ms: Keyword.get(opts, :timeout_ms, 120_000)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

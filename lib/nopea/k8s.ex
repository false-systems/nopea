defmodule Nopea.K8s do
  @moduledoc """
  Kubernetes API client wrapper.

  Provides:
  - Connection management (in-cluster or kubeconfig)
  - Resource apply/get/delete via server-side apply
  """

  @behaviour Nopea.K8s.Behaviour

  require Logger

  @impl true
  @spec conn() :: {:ok, K8s.Conn.t()} | {:error, term()}
  def conn do
    case Application.get_env(:nopea, :k8s_conn) do
      nil ->
        case K8s.Conn.from_service_account() do
          {:ok, conn} -> {:ok, conn}
          {:error, _} -> K8s.Conn.from_file("~/.kube/config")
        end

      conn ->
        {:ok, conn}
    end
  end

  @spec apply_manifest(map(), String.t() | nil) :: :ok | {:error, term()}
  def apply_manifest(manifest, target_namespace \\ nil) do
    with {:ok, conn} <- conn() do
      Nopea.Applier.apply_single(manifest, conn, target_namespace)
    end
  end

  @impl true
  @spec apply_manifests([map()], String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def apply_manifests(manifests, target_namespace \\ nil) do
    with {:ok, conn} <- conn() do
      Nopea.Applier.apply_manifests(manifests, conn, target_namespace)
    end
  end

  @impl true
  @spec get_resource(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def get_resource(api_version, kind, name, namespace) do
    with {:ok, conn} <- conn() do
      operation = K8s.Client.get(api_version, kind, namespace: namespace, name: name)
      K8s.Client.run(conn, operation)
    end
  end

  @spec delete_resource(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def delete_resource(api_version, kind, name, namespace) do
    with {:ok, conn} <- conn() do
      operation = K8s.Client.delete(api_version, kind, namespace: namespace, name: name)

      case K8s.Client.run(conn, operation) do
        {:ok, _} -> :ok
        {:error, %K8s.Client.APIError{reason: "NotFound"}} -> :ok
        {:error, _} = error -> error
      end
    end
  end
end

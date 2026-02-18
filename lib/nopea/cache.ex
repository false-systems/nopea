defmodule Nopea.Cache do
  @moduledoc """
  ETS-based caching for deployment state.

  Provides in-memory storage for:
  - Deployment records per service
  - Service state (last deploy, status)
  - Graph snapshots for persistence
  - Last applied manifests for drift detection
  """

  use GenServer
  require Logger

  @deployments_table :nopea_deployments
  @service_state_table :nopea_service_state
  @graph_snapshot_table :nopea_graph_snapshot
  @last_applied_table :nopea_last_applied

  # Client API

  @spec available?() :: boolean()
  def available? do
    :ets.whereis(@deployments_table) != :undefined and
      :ets.whereis(@service_state_table) != :undefined and
      :ets.whereis(@graph_snapshot_table) != :undefined and
      :ets.whereis(@last_applied_table) != :undefined
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Deployments

  @spec put_deployment(String.t(), String.t(), map()) :: :ok
  def put_deployment(service, deploy_id, data) do
    :ets.insert(@deployments_table, {{service, deploy_id}, data, DateTime.utc_now()})
    :ok
  end

  @spec get_deployment(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_deployment(service, deploy_id) do
    case :ets.lookup(@deployments_table, {service, deploy_id}) do
      [{{^service, ^deploy_id}, data, _ts}] -> {:ok, data}
      [] -> {:error, :not_found}
    end
  end

  @spec list_deployments(String.t()) :: [map()]
  def list_deployments(service) do
    @deployments_table
    |> :ets.match({{service, :_}, :"$1", :_})
    |> Enum.map(fn [data] -> data end)
  end

  # Service State

  @spec put_service_state(String.t(), map()) :: :ok
  def put_service_state(service, state) do
    :ets.insert(@service_state_table, {service, state})
    :ok
  end

  @spec get_service_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_service_state(service) do
    case :ets.lookup(@service_state_table, service) do
      [{^service, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @spec list_services() :: [String.t()]
  def list_services do
    @service_state_table
    |> :ets.match({:"$1", :_})
    |> Enum.map(fn [svc] -> svc end)
  end

  # Graph Snapshot

  @spec put_graph_snapshot(binary()) :: :ok
  def put_graph_snapshot(binary) do
    :ets.insert(@graph_snapshot_table, {:snapshot, binary, DateTime.utc_now()})
    :ok
  end

  @spec get_graph_snapshot() :: {:ok, binary()} | {:error, :not_found}
  def get_graph_snapshot do
    case :ets.lookup(@graph_snapshot_table, :snapshot) do
      [{:snapshot, binary, _ts}] -> {:ok, binary}
      [] -> {:error, :not_found}
    end
  end

  # Last Applied Manifests (for drift detection)

  @spec put_last_applied(String.t(), String.t(), map()) :: :ok
  def put_last_applied(service, resource_key, manifest) do
    :ets.insert(@last_applied_table, {{service, resource_key}, manifest, DateTime.utc_now()})
    :ok
  end

  @spec get_last_applied(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_last_applied(service, resource_key) do
    case :ets.lookup(@last_applied_table, {service, resource_key}) do
      [{{^service, ^resource_key}, manifest, _ts}] -> {:ok, manifest}
      [] -> {:error, :not_found}
    end
  end

  @spec list_last_applied(String.t()) :: [{String.t(), map()}]
  def list_last_applied(service) do
    @last_applied_table
    |> :ets.match({{service, :"$1"}, :"$2", :_})
    |> Enum.map(fn [key, manifest] -> {key, manifest} end)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@deployments_table, [:set, :public, :named_table])
    :ets.new(@service_state_table, [:set, :public, :named_table])
    :ets.new(@graph_snapshot_table, [:set, :public, :named_table])
    :ets.new(@last_applied_table, [:set, :public, :named_table])

    Logger.info("Cache started with deployment ETS tables")

    {:ok, %{}}
  end
end

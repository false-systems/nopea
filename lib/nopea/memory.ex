defmodule Nopea.Memory do
  @moduledoc """
  GenServer wrapping a knowledge graph for deployment memory.

  Maintains an in-memory graph that learns from every deployment:
  - Services and their deployment history
  - Failure patterns and dependencies
  - EWMA-weighted confidence scores that decay over time

  The graph enables context-aware deployments: "auth-service deploys
  fail when redis is also updating" (0.85 confidence, seen 4 times).

  ## Persistence

  Graph is persisted to `.nopea/graph.etf` alongside ETS snapshots.
  On startup, restore order: ETS snapshot → disk → fresh graph.
  """

  use GenServer
  require Logger

  alias Nopea.Graph.Graph

  defstruct [:graph, :decay_timer, :workdir]

  @decay_interval_ms :timer.hours(1)
  @decay_factor 0.98
  @graph_version <<1>>

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec get_graph() :: Graph.t()
  def get_graph do
    GenServer.call(__MODULE__, :get_graph)
  end

  @spec get_deploy_context(String.t(), String.t()) :: map()
  def get_deploy_context(service, namespace) do
    GenServer.call(__MODULE__, {:get_deploy_context, service, namespace})
  end

  @spec record_deploy(map()) :: :ok
  def record_deploy(deploy_result) do
    GenServer.cast(__MODULE__, {:record_deploy, deploy_result})
  end

  @spec node_count() :: non_neg_integer()
  def node_count do
    GenServer.call(__MODULE__, :node_count)
  end

  @spec relationship_count() :: non_neg_integer()
  def relationship_count do
    GenServer.call(__MODULE__, :relationship_count)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    workdir = Keyword.get(opts, :workdir, File.cwd!())
    graph = restore_snapshot(opts) || restore_from_disk(workdir) || Graph.new()
    timer = schedule_decay()

    Logger.info("Memory started",
      node_count: Graph.node_count(graph),
      relationship_count: Graph.relationship_count(graph)
    )

    {:ok, %__MODULE__{graph: graph, decay_timer: timer, workdir: workdir}}
  end

  @impl true
  def handle_call(:get_graph, _from, state) do
    {:reply, state.graph, state}
  end

  def handle_call({:get_deploy_context, service, namespace}, _from, state) do
    context = Nopea.Memory.Query.deploy_context(state.graph, service, namespace)
    {:reply, context, state}
  end

  def handle_call(:node_count, _from, state) do
    {:reply, Graph.node_count(state.graph), state}
  end

  def handle_call(:relationship_count, _from, state) do
    {:reply, Graph.relationship_count(state.graph), state}
  end

  @impl true
  def handle_cast({:record_deploy, deploy_result}, state) do
    try do
      graph = Nopea.Memory.Ingestor.ingest(state.graph, deploy_result)
      snapshot_graph(graph)
      persist_to_disk(graph, state.workdir)
      {:noreply, %{state | graph: graph}}
    rescue
      error ->
        Logger.error("Ingestor failed, preserving existing graph state",
          error: inspect(error),
          stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:decay, state) do
    graph = Graph.decay_all(state.graph, @decay_factor)
    timer = schedule_decay()
    persist_to_disk(graph, state.workdir)

    Logger.debug("Memory decay applied", node_count: Graph.node_count(graph))

    {:noreply, %{state | graph: graph, decay_timer: timer}}
  end

  @impl true
  def terminate(_reason, state) do
    persist_to_disk(state.graph, state.workdir)
    :ok
  end

  # Private

  defp schedule_decay do
    Process.send_after(self(), :decay, @decay_interval_ms)
  end

  defp restore_snapshot(_opts) do
    case Nopea.Cache.available?() && Nopea.Cache.get_graph_snapshot() do
      {:ok, binary} ->
        try do
          :erlang.binary_to_term(binary, [:safe])
        rescue
          error ->
            Logger.warning("Failed to restore graph snapshot",
              error: inspect(error),
              stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
            )

            nil
        end

      _ ->
        nil
    end
  end

  defp snapshot_graph(graph) do
    if Nopea.Cache.available?() do
      binary = :erlang.term_to_binary(graph)
      Nopea.Cache.put_graph_snapshot(binary)
    end
  end

  defp persist_to_disk(graph, workdir) do
    path = graph_path(workdir)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      binary = @graph_version <> :erlang.term_to_binary(graph)
      File.write(path, binary)
    end
  rescue
    error ->
      Logger.warning("Failed to persist graph to disk",
        error: inspect(error)
      )
  end

  defp restore_from_disk(workdir) do
    path = graph_path(workdir)

    case File.read(path) do
      {:ok, <<1, rest::binary>>} ->
        :erlang.binary_to_term(rest, [:safe])

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp graph_path(workdir) do
    Path.join([workdir, ".nopea", "graph.etf"])
  end
end

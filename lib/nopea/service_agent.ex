defmodule Nopea.ServiceAgent do
  @moduledoc """
  Per-service GenServer that serializes deploys and tracks state.

  Each active service gets a long-lived process that:
  - Serializes concurrent deploys via an internal queue
  - Tracks deploy count and last result
  - Recovers from crashes via supervisor restart

  State machine:
    :idle  --deploy request--> :deploying
    :deploying --worker done--> :idle  (reply, dequeue next)
    :deploying --worker crash--> :idle (reply with failure, dequeue next)
    :deploying --new request--> :deploying (enqueue)

  MCP users never interact with this directly — they call Deploy.deploy/1
  which routes here transparently.
  """

  use GenServer
  require Logger

  alias Nopea.Deploy.{Spec, Result}

  @crash_cooldown_ms 2_000

  defstruct [
    :service,
    :current_deploy,
    queue: :queue.new(),
    deploy_count: 0,
    last_result: nil,
    status: :idle
  ]

  @type t :: %__MODULE__{
          service: String.t(),
          current_deploy: map() | nil,
          queue: :queue.queue(),
          deploy_count: non_neg_integer(),
          last_result: Result.t() | nil,
          status: :idle | :deploying
        }

  # Client API

  @spec deploy(String.t(), Spec.t()) :: Result.t()
  def deploy(service, %Spec{} = spec) do
    agent = ensure_started(service)
    GenServer.call(agent, {:deploy, spec}, :infinity)
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(service) do
    if registry_available?() do
      case lookup(service) do
        {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
        :error -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  @spec health() :: [map()]
  def health do
    if registry_available?() do
      Registry.select(Nopea.Registry, [
        {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])
      |> Enum.filter(fn
        {{:service, _name}, _pid} -> true
        _ -> false
      end)
      |> Enum.map(fn {{:service, name}, pid} ->
        try do
          GenServer.call(pid, :status, 5_000)
        catch
          :exit, _ -> %{service: name, status: :unavailable}
        end
      end)
    else
      []
    end
  end

  @spec ensure_started(String.t()) :: pid()
  def ensure_started(service) do
    case lookup(service) do
      {:ok, pid} ->
        pid

      :error ->
        case Nopea.ServiceAgent.Supervisor.start_agent(service) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp registry_available? do
    Process.whereis(Nopea.Registry) != nil
  end

  defp lookup(service) do
    case Registry.lookup(Nopea.Registry, {:service, service}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # Server

  def start_link(service) do
    GenServer.start_link(__MODULE__, service,
      name: {:via, Registry, {Nopea.Registry, {:service, service}}}
    )
  end

  @impl true
  def init(service) do
    Logger.info("ServiceAgent started", service: service)

    state = %__MODULE__{service: service}

    # Recover last known state from cache if available
    state =
      if Nopea.Cache.available?() do
        case Nopea.Cache.get_service_state(service) do
          {:ok, cached} ->
            %{state | last_result: cached[:last_result]}

          {:error, :not_found} ->
            state
        end
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:deploy, spec}, from, %{status: :idle} = state) do
    {state, _deploy_id} = start_deploy(spec, from, state)
    {:noreply, state}
  end

  def handle_call({:deploy, spec}, from, %{status: :deploying} = state) do
    queue = :queue.in({spec, from}, state.queue)
    {:noreply, %{state | queue: queue}}
  end

  def handle_call(:status, _from, state) do
    reply = %{
      service: state.service,
      status: state.status,
      deploy_count: state.deploy_count,
      queue_length: :queue.len(state.queue),
      last_result:
        case state.last_result do
          %Result{} = r -> %{status: r.status, deploy_id: r.deploy_id, duration_ms: r.duration_ms}
          other -> other
        end
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:deploy_result, deploy_id, result}, state) do
    state = handle_deploy_complete(deploy_id, result, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    state = handle_deploy_down(ref, reason, state)
    {:noreply, state}
  end

  def handle_info(:cooldown_dequeue, %{status: :idle} = state) do
    {:noreply, maybe_dequeue(state)}
  end

  def handle_info(:cooldown_dequeue, state) do
    # Already deploying — the dequeue will happen naturally when current finishes
    {:noreply, state}
  end

  # Deploy execution

  defp start_deploy(spec, from, state) do
    deploy_id = Nopea.Helpers.generate_ulid()
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = Nopea.Deploy.run(spec)
        send(parent, {:deploy_result, deploy_id, result})
      end)

    current = %{
      deploy_id: deploy_id,
      spec: spec,
      from: from,
      pid: pid,
      ref: ref,
      started_at: System.monotonic_time()
    }

    {%{state | status: :deploying, current_deploy: current}, deploy_id}
  end

  defp handle_deploy_complete(deploy_id, result, state) do
    case state.current_deploy do
      %{deploy_id: ^deploy_id, from: from, ref: ref} ->
        # Demonitor to avoid getting :DOWN after successful result
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)

        %{state | deploy_count: state.deploy_count + 1, last_result: result}
        |> clear_current()
        |> maybe_dequeue()

      _ ->
        # Stale result from a previous deploy — ignore
        state
    end
  end

  defp handle_deploy_down(ref, reason, state) do
    case state.current_deploy do
      %{ref: ^ref, from: from, spec: spec} ->
        error_result =
          Result.failure(
            state.current_deploy.deploy_id,
            spec,
            spec.strategy || :direct,
            {:worker_crash, reason},
            duration_ms(state.current_deploy.started_at)
          )

        Logger.warning("Deploy worker crashed, cooldown before next deploy",
          service: state.service,
          deploy_id: state.current_deploy.deploy_id,
          reason: inspect(reason),
          cooldown_ms: @crash_cooldown_ms,
          queued: :queue.len(state.queue)
        )

        GenServer.reply(from, error_result)

        state =
          %{state | deploy_count: state.deploy_count + 1, last_result: error_result}
          |> clear_current()

        # Cooldown: delay dequeue to protect broken services from rapid retries
        if not :queue.is_empty(state.queue) do
          Process.send_after(self(), :cooldown_dequeue, @crash_cooldown_ms)
        end

        state

      _ ->
        # DOWN for a process we don't track — ignore
        state
    end
  end

  defp clear_current(state) do
    %{state | status: :idle, current_deploy: nil}
  end

  defp maybe_dequeue(state) do
    case :queue.out(state.queue) do
      {{:value, {spec, from}}, rest} ->
        {state, _} = start_deploy(spec, from, %{state | queue: rest})
        state

      {:empty, _} ->
        state
    end
  end

  defp duration_ms(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end
end

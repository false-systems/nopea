defmodule Nopea.Progressive.Monitor do
  @moduledoc """
  Per-rollout GenServer that monitors a progressive delivery rollout.

  Polls the Kulta Rollout CRD status and updates the rollout phase.
  Supports manual promote (advance/complete) and rollback (abort).
  Self-terminates on completion, failure, or timeout.
  """

  use GenServer
  require Logger

  alias Nopea.Progressive.Rollout

  @poll_interval_ms 10_000
  @max_duration_ms 3_600_000

  @kulta_api_version "kulta.io/v1alpha1"
  @kulta_kind "Rollout"

  defstruct [:rollout, :spec, :poll_timer, :deadline]

  # Client API

  @spec start_link({String.t(), Nopea.Deploy.Spec.t(), :canary | :blue_green}) ::
          GenServer.on_start()
  def start_link({deploy_id, spec, strategy}) do
    GenServer.start_link(__MODULE__, {deploy_id, spec, strategy}, name: via(deploy_id))
  end

  @spec promote(String.t()) :: {:ok, Rollout.t()} | {:error, term()}
  def promote(deploy_id) do
    GenServer.call(via(deploy_id), :promote)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @spec rollback(String.t()) :: {:ok, Rollout.t()} | {:error, term()}
  def rollback(deploy_id) do
    GenServer.call(via(deploy_id), :rollback)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @spec status(String.t()) :: {:ok, Rollout.t()} | {:error, :not_found}
  def status(deploy_id) do
    GenServer.call(via(deploy_id), :status)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc false
  @spec whereis(String.t()) :: pid() | nil
  def whereis(deploy_id) do
    case Registry.lookup(Nopea.Registry, {:rollout, deploy_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @spec list_active() :: [Rollout.t()]
  def list_active do
    if Process.whereis(Nopea.Registry) do
      Registry.select(Nopea.Registry, [
        {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])
      |> Enum.flat_map(fn
        {{:rollout, _deploy_id}, pid} ->
          try do
            case GenServer.call(pid, :status, 5_000) do
              {:ok, rollout} -> [rollout]
              _ -> []
            end
          catch
            :exit, _ -> []
          end

        _ ->
          []
      end)
    else
      []
    end
  end

  # Server

  @impl true
  def init({deploy_id, spec, strategy}) do
    rollout = Rollout.new(deploy_id, spec.service, spec.namespace, strategy)
    deadline = System.monotonic_time(:millisecond) + @max_duration_ms

    Logger.info("Progressive monitor started",
      deploy_id: deploy_id,
      service: spec.service,
      strategy: strategy
    )

    timer = schedule_poll()

    {:ok,
     %__MODULE__{
       rollout: rollout,
       spec: spec,
       poll_timer: timer,
       deadline: deadline
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, state.rollout}, state}
  end

  def handle_call(:promote, _from, state) do
    case do_promote(state) do
      {:ok, rollout} ->
        state = %{state | rollout: rollout}

        if terminal?(rollout.phase) do
          {:stop, :normal, {:ok, rollout}, state}
        else
          {:reply, {:ok, rollout}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:rollback, _from, state) do
    case do_rollback(state) do
      {:ok, rollout} ->
        state = %{state | rollout: rollout}
        {:stop, :normal, {:ok, rollout}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    now_ms = System.monotonic_time(:millisecond)

    if now_ms >= state.deadline do
      Logger.warning("Progressive rollout timed out",
        deploy_id: state.rollout.deploy_id,
        service: state.rollout.service
      )

      rollout = update_phase(state.rollout, :failed)
      record_outcome(rollout)
      {:stop, :normal, %{state | rollout: rollout}}
    else
      state = poll_rollout_status(state)

      if terminal?(state.rollout.phase) do
        record_outcome(state.rollout)
        {:stop, :normal, state}
      else
        timer = schedule_poll()
        {:noreply, %{state | poll_timer: timer}}
      end
    end
  end

  # Private

  defp via(deploy_id) do
    {:via, Registry, {Nopea.Registry, {:rollout, deploy_id}}}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp poll_rollout_status(state) do
    rollout = state.rollout

    case k8s_module().get_resource(
           @kulta_api_version,
           @kulta_kind,
           rollout.service,
           rollout.namespace
         ) do
      {:ok, resource} ->
        new_rollout = parse_rollout_status(rollout, resource)
        %{state | rollout: new_rollout}

      {:error, reason} ->
        Logger.warning("Failed to poll rollout status",
          deploy_id: rollout.deploy_id,
          error: inspect(reason)
        )

        state
    end
  end

  @phase_map %{
    "healthy" => :completed,
    "completed" => :completed,
    "degraded" => :degraded,
    "paused" => :paused,
    "failed" => :failed
  }

  defp parse_rollout_status(rollout, resource) do
    status = get_in(resource, ["status"]) || %{}
    phase_str = status["phase"] || "Progressing"
    phase = Map.get(@phase_map, String.downcase(phase_str), :progressing)

    %{
      rollout
      | phase: phase,
        current_step: status["currentStepIndex"] || rollout.current_step,
        total_steps: status["totalSteps"] || rollout.total_steps,
        updated_at: DateTime.utc_now()
    }
  end

  defp do_promote(state) do
    rollout = state.rollout

    patch = %{
      "metadata" => %{
        "annotations" => %{"kulta.io/promote" => "true"}
      }
    }

    case k8s_module().patch_resource(
           @kulta_api_version,
           @kulta_kind,
           rollout.service,
           rollout.namespace,
           patch
         ) do
      {:ok, _} ->
        {:ok, update_phase(rollout, :promoted)}

      {:error, _} = error ->
        error
    end
  end

  defp do_rollback(state) do
    rollout = state.rollout

    case k8s_module().delete_resource(
           @kulta_api_version,
           @kulta_kind,
           rollout.service,
           rollout.namespace
         ) do
      :ok ->
        {:ok, update_phase(rollout, :failed)}

      {:error, _} = error ->
        error
    end
  end

  defp update_phase(rollout, phase) do
    %{rollout | phase: phase, updated_at: DateTime.utc_now()}
  end

  defp terminal?(phase), do: phase in [:completed, :promoted, :failed]

  defp record_outcome(rollout) do
    if Process.whereis(Nopea.Memory) do
      status = if rollout.phase in [:completed, :promoted], do: :completed, else: :failed

      Nopea.Memory.record_deploy(%{
        service: rollout.service,
        namespace: rollout.namespace,
        status: status,
        error: if(status == :failed, do: :rollout_failed),
        duration_ms: DateTime.diff(rollout.updated_at, rollout.started_at, :millisecond),
        concurrent_deploys: []
      })
    end
  end

  defp k8s_module do
    Application.get_env(:nopea, :k8s_module, Nopea.K8s)
  end
end

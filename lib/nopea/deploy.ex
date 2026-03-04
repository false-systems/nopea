defmodule Nopea.Deploy do
  @moduledoc """
  Deployment orchestration entry point.

  Orchestrates the full deploy lifecycle:
  1. Load memory context for the service
  2. Select strategy based on context
  3. Execute deployment via strategy
  4. Verify with post-deploy drift check
  5. Record outcome in memory
  """

  require Logger

  alias Nopea.Deploy.{Spec, Result}

  @doc """
  Deploy through ServiceAgent when available, falling back to direct execution.

  This is the primary entry point for MCP and external callers.
  """
  @spec deploy(Spec.t()) :: Result.t()
  def deploy(%Spec{} = spec) do
    if Process.whereis(Nopea.ServiceAgent.Supervisor) != nil do
      Nopea.ServiceAgent.deploy(spec.service, spec)
    else
      run(spec)
    end
  end

  @spec run(Spec.t()) :: Result.t()
  def run(%Spec{} = spec) do
    deploy_id = Nopea.Helpers.generate_ulid()
    start_time = System.monotonic_time()

    Logger.info("Deploy started",
      service: spec.service,
      namespace: spec.namespace,
      deploy_id: deploy_id
    )

    # 1. Get memory context
    context = get_context(spec)

    # 2. Select strategy
    strategy = select_strategy(spec, context)

    Logger.info("Strategy selected",
      service: spec.service,
      strategy: strategy,
      auto_selected: is_nil(spec.strategy)
    )

    # 3. Emit start event
    emit_start(spec, deploy_id, strategy)

    # 4. Execute
    case execute_strategy(strategy, spec) do
      {:ok, applied} ->
        duration_ms = duration_ms(start_time)

        # 5. Verify
        verified = verify_deploy(spec, applied)

        # 6. Record success
        result = Result.success(deploy_id, spec, strategy, applied, duration_ms, verified)
        record_outcome(result, context)
        emit_complete(spec, deploy_id, strategy, duration_ms, verified)

        Logger.info("Deploy completed",
          service: spec.service,
          deploy_id: deploy_id,
          duration_ms: duration_ms,
          verified: verified
        )

        result

      {:error, reason} ->
        duration_ms = duration_ms(start_time)
        result = Result.failure(deploy_id, spec, strategy, reason, duration_ms)
        record_outcome(result, context)
        emit_failure(spec, deploy_id, strategy, reason, duration_ms, start_time)

        Logger.error("Deploy failed",
          service: spec.service,
          deploy_id: deploy_id,
          error: inspect(reason),
          duration_ms: duration_ms
        )

        result
    end
  end

  @spec execute(map()) :: {:ok, term()} | {:error, term()}
  def execute(%{} = spec_map) do
    spec = Spec.from_map(spec_map)
    result = run(spec)

    case result.status do
      :completed -> {:ok, result}
      :failed -> {:error, result.error}
    end
  end

  # Private

  defp get_context(spec) do
    if Process.whereis(Nopea.Memory) do
      Nopea.Memory.get_deploy_context(spec.service, spec.namespace)
    else
      %{known: false, failure_patterns: [], dependencies: [], recommendations: []}
    end
  end

  defp select_strategy(%Spec{strategy: strategy}, _context)
       when strategy in [:direct, :canary, :blue_green] do
    strategy
  end

  defp select_strategy(%Spec{strategy: nil}, %{known: true, failure_patterns: patterns})
       when is_list(patterns) do
    threshold = Application.get_env(:nopea, :canary_threshold, 0.15)

    if Enum.any?(patterns, fn p -> p.confidence > threshold end),
      do: :canary,
      else: :direct
  end

  defp select_strategy(%Spec{strategy: nil}, _context), do: :direct

  defp select_strategy(%Spec{strategy: other}, _context) do
    Logger.warning("Unknown strategy, falling back to direct",
      strategy: inspect(other)
    )

    :direct
  end

  defp execute_strategy(:direct, spec), do: Nopea.Strategy.Direct.execute(spec)

  defp execute_strategy(strategy, spec) when strategy in [:canary, :blue_green] do
    case Nopea.Kulta.RolloutBuilder.build(spec, strategy) do
      {:ok, rollout} ->
        k8s_module().apply_manifest(rollout, spec.namespace)
        |> case do
          {:ok, applied} -> {:ok, [applied]}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp k8s_module do
    Application.get_env(:nopea, :k8s_module, Nopea.K8s)
  end

  defp verify_deploy(spec, applied) when is_list(applied) do
    Enum.all?(applied, fn manifest ->
      case Nopea.Drift.verify_manifest(spec.service, manifest, k8s_module: k8s_module()) do
        :no_drift -> true
        :new_resource -> true
        _ -> false
      end
    end)
  end

  defp verify_deploy(_spec, _applied), do: false

  defp record_outcome(result, context) do
    if Process.whereis(Nopea.Memory) do
      Nopea.Memory.record_deploy(%{
        service: result.service,
        namespace: result.namespace,
        status: result.status,
        error: result.error,
        duration_ms: result.duration_ms,
        concurrent_deploys: get_concurrent_services(result.service)
      })
    end

    if Nopea.Cache.available?() do
      Nopea.Cache.put_deployment(result.service, result.deploy_id, Map.from_struct(result))

      Nopea.Cache.put_service_state(result.service, %{
        status: result.status,
        last_deploy: result.deploy_id,
        last_deploy_at: DateTime.utc_now()
      })
    end

    # Generate FALSE Protocol occurrence
    generate_occurrence(result, context)
  end

  defp generate_occurrence(result, context) do
    occurrence_input = %{
      service: result.service,
      namespace: result.namespace,
      strategy: result.strategy,
      status: result.status,
      deploy_id: result.deploy_id,
      manifests_applied: result.manifest_count,
      duration_ms: result.duration_ms,
      verified: result.verified,
      error: result.error,
      applied_resources: result.applied_resources
    }

    memory_context =
      if context && context[:known] do
        context
      else
        nil
      end

    occurrence = Nopea.Occurrence.build(occurrence_input, memory_context)

    # Start log emitter and emit key deploy events
    occurrence = emit_deploy_logs(occurrence, result)

    # Persist to .nopea/ directory
    workdir = File.cwd!()

    case Nopea.Occurrence.persist(occurrence, workdir) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to persist occurrence",
          service: result.service,
          deploy_id: result.deploy_id,
          error: inspect(reason)
        )
    end
  rescue
    error ->
      Logger.error("Failed to generate occurrence: #{Exception.message(error)}",
        service: result.service,
        deploy_id: result.deploy_id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )
  end

  defp emit_deploy_logs(occurrence, result) do
    case Nopea.Occurrence.start_log_emitter(occurrence) do
      {:ok, emitter} ->
        log_deploy_start(emitter, result)
        emit_status_log(emitter, result)
        Nopea.Occurrence.attach_log_ref(occurrence, emitter)

      {:error, reason} ->
        Logger.warning("Failed to start deploy log emitter",
          service: result.service,
          reason: inspect(reason)
        )

        occurrence
    end
  end

  defp log_deploy_start(emitter, result) do
    case FalseProtocol.LogEmitter.info_full(
           emitter,
           "deploy started for #{result.service}",
           %FalseProtocol.Semantic{
             event: "deploy.apply.start",
             what_happened:
               "started applying #{result.manifest_count} manifests to #{result.namespace}"
           }
         ) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to emit deploy start log", reason: inspect(reason))
    end
  end

  defp emit_status_log(emitter, %{status: :completed} = result) do
    case FalseProtocol.LogEmitter.info_full(
           emitter,
           "deploy completed in #{result.duration_ms}ms",
           %FalseProtocol.Semantic{
             event: "deploy.apply.complete",
             what_happened: "#{result.service} deployed successfully",
             parameters: %{"verified" => result.verified, "duration_ms" => result.duration_ms}
           }
         ) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to emit deploy complete log", reason: inspect(reason))
    end
  end

  defp emit_status_log(emitter, %{status: :failed} = result) do
    case FalseProtocol.LogEmitter.emit(
           emitter,
           :error,
           "deploy failed: #{inspect(result.error)}",
           %FalseProtocol.Semantic{
             event: "deploy.apply.failed",
             what_happened: "#{result.service} deployment failed",
             impact: "service in #{result.namespace} is not updated"
           }
         ) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to emit deploy failed log", reason: inspect(reason))
    end
  end

  defp emit_status_log(emitter, %{status: :rolledback} = result) do
    case FalseProtocol.LogEmitter.emit(
           emitter,
           :warning,
           "deploy rolledback: #{inspect(result.error)}",
           %FalseProtocol.Semantic{
             event: "deploy.apply.rolledback",
             what_happened: "#{result.service} deployment rolled back",
             impact: "service in #{result.namespace} reverted to previous version"
           }
         ) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to emit deploy rollback log", reason: inspect(reason))
    end
  end

  defp emit_status_log(emitter, result) do
    case FalseProtocol.LogEmitter.emit(
           emitter,
           :warning,
           "deploy finished with status: #{inspect(result.status)}",
           %FalseProtocol.Semantic{
             event: "deploy.apply.unknown",
             what_happened: "#{result.service} deployment ended with status #{result.status}"
           }
         ) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to emit deploy status log", reason: inspect(reason))
    end
  end

  defp emit_start(spec, deploy_id, strategy) do
    Nopea.Metrics.emit_deploy_start(%{service: spec.service, strategy: strategy})

    if emitter_running?() do
      event =
        Nopea.Events.deploy_started(spec.service, %{
          deploy_id: deploy_id,
          strategy: strategy,
          namespace: spec.namespace,
          manifest_count: length(spec.manifests)
        })

      Nopea.Events.Emitter.emit(Nopea.Events.Emitter, event)
    end
  end

  defp emit_complete(spec, deploy_id, strategy, duration_ms, verified) do
    if emitter_running?() do
      event =
        Nopea.Events.deploy_completed(spec.service, %{
          deploy_id: deploy_id,
          strategy: strategy,
          namespace: spec.namespace,
          duration_ms: duration_ms,
          verified: verified
        })

      Nopea.Events.Emitter.emit(Nopea.Events.Emitter, event)
    end
  end

  defp emit_failure(spec, deploy_id, strategy, reason, duration_ms, start_time) do
    Nopea.Metrics.emit_deploy_error(start_time, %{
      service: spec.service,
      strategy: strategy,
      error: reason
    })

    if emitter_running?() do
      event =
        Nopea.Events.deploy_failed(spec.service, %{
          deploy_id: deploy_id,
          strategy: strategy,
          namespace: spec.namespace,
          error: reason,
          duration_ms: duration_ms
        })

      Nopea.Events.Emitter.emit(Nopea.Events.Emitter, event)
    end
  end

  defp emitter_running?, do: Process.whereis(Nopea.Events.Emitter) != nil

  defp get_concurrent_services(current_service) do
    if Process.whereis(Nopea.Registry) do
      Registry.select(Nopea.Registry, [
        {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])
      |> Enum.flat_map(fn
        {{:service, name}, pid} when name != current_service ->
          try do
            case GenServer.call(pid, :status, 1_000) do
              %{status: :deploying} -> [name]
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

  defp duration_ms(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end
end

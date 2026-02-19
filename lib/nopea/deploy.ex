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

  defp execute_strategy(other, spec) do
    Logger.warning("Unrecognized strategy, falling back to direct",
      service: spec.service,
      strategy: inspect(other)
    )

    Nopea.Strategy.Direct.execute(spec)
  end

  defp k8s_module do
    Application.get_env(:nopea, :k8s_module, Nopea.K8s)
  end

  defp verify_deploy(spec, applied) when is_list(applied) do
    Enum.all?(applied, fn manifest ->
      case Nopea.Drift.verify_manifest(spec.service, manifest) do
        :no_drift -> true
        :new_resource -> true
        _ -> false
      end
    end)
  rescue
    error ->
      Logger.warning("Post-deploy verification failed",
        service: spec.service,
        error: inspect(error),
        stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
      )

      false
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
        concurrent_deploys: []
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
      error: result.error
    }

    memory_context =
      if context && context[:known] do
        context
      else
        nil
      end

    occurrence = Nopea.Occurrence.build(occurrence_input, memory_context)

    # Persist to .nopea/ directory
    workdir = File.cwd!()
    Nopea.Occurrence.persist(occurrence, workdir)
  rescue
    error ->
      Logger.error("Failed to generate occurrence",
        service: result.service,
        deploy_id: result.deploy_id,
        error: inspect(error),
        stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
      )
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

  defp duration_ms(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)
  end
end

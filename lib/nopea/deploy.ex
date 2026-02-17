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

  @spec run(Spec.t()) :: Result.t()
  def run(%Spec{} = spec) do
    deploy_id = Nopea.Helpers.generate_ulid()
    start_time = System.monotonic_time()

    Logger.info("Deploy started: #{spec.service}/#{spec.namespace} [#{deploy_id}]")

    # 1. Get memory context
    context = get_context(spec)

    # 2. Select strategy
    strategy = select_strategy(spec, context)

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

        Logger.info("Deploy completed: #{spec.service} [#{deploy_id}] in #{duration_ms}ms")
        result

      {:error, reason} ->
        duration_ms = duration_ms(start_time)
        result = Result.failure(deploy_id, spec, strategy, reason, duration_ms)
        record_outcome(result, context)
        emit_failure(spec, deploy_id, strategy, reason, duration_ms, start_time)

        Logger.error("Deploy failed: #{spec.service} [#{deploy_id}]: #{inspect(reason)}")
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

  defp select_strategy(%Spec{strategy: strategy}, _context) when not is_nil(strategy) do
    strategy
  end

  defp select_strategy(_spec, %{failure_patterns: patterns}) do
    high_risk = Enum.any?(patterns, fn p -> p.confidence > 0.15 end)
    if high_risk, do: :canary, else: :direct
  end

  defp select_strategy(_spec, _context), do: :direct

  defp execute_strategy(:direct, spec), do: Nopea.Strategy.Direct.execute(spec)
  defp execute_strategy(:canary, spec), do: Nopea.Strategy.Canary.execute(spec)
  defp execute_strategy(:blue_green, spec), do: Nopea.Strategy.BlueGreen.execute(spec)
  defp execute_strategy(_, spec), do: Nopea.Strategy.Direct.execute(spec)

  defp verify_deploy(spec, applied) when is_list(applied) do
    Enum.all?(applied, fn manifest ->
      case Nopea.Drift.verify_manifest(spec.service, manifest) do
        :no_drift -> true
        :new_resource -> true
        _ -> false
      end
    end)
  rescue
    _ -> false
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
      Logger.warning("Failed to generate occurrence: #{inspect(error)}")
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

defmodule Nopea.Occurrence do
  @moduledoc """
  Generates FALSE Protocol occurrences for deployment events.

  Adapts `Nopea.Deploy.Result` into `FalseProtocol.Occurrence` structs with:
  - **Error block** — what_failed, why_it_matters, possible_causes
  - **Reasoning block** — summary + memory context from knowledge graph
  - **History block** — deployment steps with timestamps and outcomes
  - **Context** — namespace + entities from applied K8s resources
  - **Deploy data** — service, namespace, strategy, manifests, duration

  ## FALSE Protocol Type Hierarchy

      deploy.run.completed   — deployment succeeded
      deploy.run.failed      — deployment failed
      deploy.run.rolledback  — deployment was rolled back
  """

  alias FalseProtocol.{Occurrence, Error, Reasoning, History, HistoryStep, Entity, PatternMatch}

  @doc """
  Builds a FALSE Protocol occurrence from a deploy result.

  Optional second argument provides memory context from the knowledge graph
  to enrich the reasoning block.
  """
  @spec build(map(), map() | nil) :: Occurrence.t()
  def build(result, memory_context \\ nil) do
    {type_suffix, severity, outcome} = classify(result.status)

    case Occurrence.new("nopea", "deploy.run.#{type_suffix}",
           severity: severity,
           outcome: outcome
         ) do
      {:ok, occ} ->
        occ
        |> maybe_set_namespace(result)
        |> maybe_add_entities(result)
        |> Occurrence.with_data(build_deploy_data(result))
        |> Occurrence.with_history(build_history(result))
        |> maybe_add_error(result)
        |> maybe_add_reasoning(result, memory_context)

      {:error, reason} ->
        raise "FalseProtocol.Occurrence.new failed: #{inspect(reason)}"
    end
  end

  @doc """
  Starts a `FalseProtocol.LogEmitter` for the given occurrence.

  Mode is `:both` — deploy logs are human-readable AND AI-structured.
  """
  @spec start_log_emitter(Occurrence.t()) :: {:ok, pid()} | {:error, term()}
  def start_log_emitter(%Occurrence{} = occ) do
    FalseProtocol.LogEmitter.start_link(occ.id, "nopea", :both)
  end

  @doc """
  Attaches the log emitter's current ref to the occurrence.
  """
  @spec attach_log_ref(Occurrence.t(), pid()) :: Occurrence.t()
  def attach_log_ref(%Occurrence{} = occ, emitter) do
    %{occ | log_ref: FalseProtocol.LogEmitter.log_ref(emitter)}
  end

  @spec persist(Occurrence.t(), String.t()) :: :ok | {:error, term()}
  def persist(%Occurrence{} = occurrence, workdir) do
    dir = Path.join(workdir, ".nopea")
    etf_dir = Path.join(dir, "occurrences")

    with {:ok, json} <- FalseProtocol.JSON.encode(occurrence),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "occurrence.json"), json),
         :ok <- File.mkdir_p(etf_dir) do
      File.write(
        Path.join(etf_dir, "#{occurrence.id}.etf"),
        :erlang.term_to_binary(occurrence)
      )
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # CLASSIFICATION
  # ─────────────────────────────────────────────────────────────────────────────

  defp classify(:completed), do: {"completed", :info, :success}
  defp classify(:failed), do: {"failed", :error, :failure}
  defp classify(:rolledback), do: {"rolledback", :warning, :failure}
  defp classify(_), do: {"failed", :error, :failure}

  # ─────────────────────────────────────────────────────────────────────────────
  # CONTEXT: NAMESPACE + ENTITIES
  # ─────────────────────────────────────────────────────────────────────────────

  defp maybe_set_namespace(occ, %{namespace: ns}) when is_binary(ns) do
    Occurrence.in_namespace(occ, ns)
  end

  defp maybe_set_namespace(occ, _), do: occ

  defp maybe_add_entities(occ, %{applied_resources: resources}) when is_list(resources) do
    Enum.reduce(resources, occ, fn resource, acc ->
      case build_entity(resource) do
        nil -> acc
        entity -> Occurrence.with_entity(acc, entity)
      end
    end)
  end

  defp maybe_add_entities(occ, _), do: occ

  defp build_entity(%{"kind" => kind, "metadata" => meta}) do
    uid = Map.get(meta, "uid", "unknown")
    name = Map.get(meta, "name", "unknown")
    namespace = Map.get(meta, "namespace")
    resource_version = Map.get(meta, "resourceVersion", "0")

    entity = Entity.from_k8s(kind, uid, name, namespace || "", resource_version)
    entity
  end

  defp build_entity(_), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # ERROR BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp maybe_add_error(occ, %{status: :completed}), do: occ

  defp maybe_add_error(occ, %{status: status, service: service, error: error} = result)
       when status in [:failed, :rolledback] do
    err = %Error{
      code: error_code(error),
      message: error_message(error),
      what_failed: "deploy of #{service} (#{result.strategy})",
      why_it_matters:
        "#{service} in #{result.namespace} is not updated — " <>
          status_impact(status, result.strategy)
    }

    Occurrence.with_error(occ, err)
  end

  defp maybe_add_error(occ, _), do: occ

  # ─────────────────────────────────────────────────────────────────────────────
  # REASONING BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp maybe_add_reasoning(occ, %{status: :completed}, _memory), do: occ

  defp maybe_add_reasoning(occ, %{status: status} = result, memory)
       when status in [:failed, :rolledback] do
    summary = build_summary(result)
    confidence = if memory && memory[:known], do: 0.8, else: 0.3

    explanation = build_explanation(result, memory)
    patterns = build_patterns(memory)

    reasoning = %Reasoning{
      summary: summary,
      explanation: explanation,
      confidence: confidence,
      patterns_matched: patterns
    }

    Occurrence.with_reasoning(occ, reasoning)
  end

  defp maybe_add_reasoning(occ, _result, _memory), do: occ

  defp build_summary(%{service: service, error: error}) do
    case error do
      {type, _msg} -> "#{service} failed — #{type}"
      nil -> "#{service} failed — cause unknown"
      other -> "#{service} failed — #{inspect(other)}"
    end
  end

  defp build_explanation(result, nil) do
    "#{result.service} deployment #{result.status} after #{result.duration_ms}ms"
  end

  defp build_explanation(result, %{recommendations: recs}) when is_list(recs) and recs != [] do
    base = "#{result.service} deployment #{result.status} after #{result.duration_ms}ms."
    base <> " " <> Enum.join(recs, " ")
  end

  defp build_explanation(result, _memory) do
    "#{result.service} deployment #{result.status} after #{result.duration_ms}ms"
  end

  defp build_patterns(nil), do: []
  defp build_patterns(%{failure_patterns: []}), do: []

  defp build_patterns(%{failure_patterns: patterns}) when is_list(patterns) do
    Enum.map(patterns, fn p ->
      %PatternMatch{
        pattern_name: to_string(p.error),
        confidence: p.confidence,
        times_seen: p.observations
      }
    end)
  end

  defp build_patterns(_), do: []

  # ─────────────────────────────────────────────────────────────────────────────
  # HISTORY BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_history(result) do
    steps = build_steps(result)

    %History{
      steps: steps,
      duration_ms: result.duration_ms
    }
  end

  defp build_steps(%{status: :completed} = result) do
    now = DateTime.utc_now()

    steps = [
      %HistoryStep{
        timestamp: now,
        action: "apply",
        description: "apply manifests",
        outcome: :success,
        duration_ms: result.duration_ms
      }
    ]

    maybe_add_verification_step(steps, result, now)
  end

  defp build_steps(%{status: :failed, error: error} = result) do
    [
      %HistoryStep{
        timestamp: DateTime.utc_now(),
        action: "apply",
        description: "apply manifests",
        outcome: :failure,
        duration_ms: result.duration_ms,
        error: %Error{
          code: error_code(error),
          message: error_message(error) || "unknown error",
          what_failed: "manifest application"
        }
      }
    ]
  end

  defp build_steps(%{status: :rolledback, error: error} = result) do
    now = DateTime.utc_now()

    [
      %HistoryStep{
        timestamp: now,
        action: "apply",
        description: "apply manifests",
        outcome: :failure,
        duration_ms: result.duration_ms,
        error: %Error{
          code: error_code(error),
          message: error_message(error) || "unknown error",
          what_failed: "manifest application"
        }
      },
      %HistoryStep{
        timestamp: now,
        action: "rollback",
        description: "rollback to previous version",
        outcome: :success
      }
    ]
  end

  defp build_steps(result) do
    [
      %HistoryStep{
        timestamp: DateTime.utc_now(),
        action: "deploy",
        description: "deploy",
        outcome: map_step_outcome(result.status)
      }
    ]
  end

  defp maybe_add_verification_step(steps, %{verified: true}, now) do
    steps ++
      [
        %HistoryStep{
          timestamp: now,
          action: "verify",
          description: "post-deploy verification",
          outcome: :success
        }
      ]
  end

  defp maybe_add_verification_step(steps, _result, _now), do: steps

  defp map_step_outcome(:completed), do: :success
  defp map_step_outcome(:failed), do: :failure
  defp map_step_outcome(:rolledback), do: :failure
  defp map_step_outcome(_), do: :failure

  # ─────────────────────────────────────────────────────────────────────────────
  # DEPLOY DATA (Domain-Specific Payload)
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_deploy_data(result) do
    data = %{
      "service" => result.service,
      "namespace" => result.namespace,
      "strategy" => to_string(result.strategy),
      "manifests_applied" => Map.get(result, :manifests_applied, 0),
      "verified" => Map.get(result, :verified, false)
    }

    case Map.get(result, :deploy_id) do
      nil -> data
      id -> Map.put(data, "deploy_id", id)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp error_code({type, _msg}) when is_atom(type), do: Atom.to_string(type)
  defp error_code(msg) when is_binary(msg), do: "error"
  defp error_code(_), do: "unknown"

  defp error_message({_type, msg}) when is_binary(msg), do: msg
  defp error_message(msg) when is_binary(msg), do: msg
  defp error_message(nil), do: nil
  defp error_message(other), do: inspect(other)

  defp status_impact(:failed, _), do: "service may be partially updated"
  defp status_impact(:rolledback, _), do: "rolled back to previous version"
  defp status_impact(_, _), do: "deployment incomplete"
end

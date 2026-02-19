defmodule Nopea.Occurrence do
  @moduledoc """
  Generates FALSE Protocol occurrences for deployment events.

  Adapts the SYKLI occurrence format for deployments:
  - **Error block** — what_failed, why_it_matters, possible_causes
  - **Reasoning block** — summary + memory context from knowledge graph
  - **History block** — deployment steps with outcomes
  - **Deploy data** — service, namespace, strategy, manifests, duration

  ## FALSE Protocol Type Hierarchy

      deploy.run.completed   — deployment succeeded
      deploy.run.failed      — deployment failed
      deploy.run.rolledback  — deployment was rolled back
  """

  @occurrence_version "1.0"

  @doc """
  Builds a FALSE Protocol occurrence from a deploy result.

  Optional second argument provides memory context from the knowledge graph
  to enrich the reasoning block.
  """
  @spec build(map(), map() | nil) :: map()
  def build(result, memory_context \\ nil) do
    {type_suffix, severity} = outcome_and_severity(result.status)

    occurrence = %{
      "version" => @occurrence_version,
      "id" => Nopea.Helpers.generate_ulid(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "nopea",
      "type" => "deploy.run.#{type_suffix}",
      "severity" => severity,
      "outcome" => type_suffix
    }

    occurrence
    |> maybe_add("error", build_error_block(result))
    |> maybe_add("reasoning", build_reasoning_block(result, memory_context))
    |> Map.put("history", build_history_block(result))
    |> Map.put("deploy_data", build_deploy_data(result))
  end

  @spec to_json(map()) :: {:ok, String.t()} | {:error, term()}
  def to_json(occurrence) do
    Jason.encode(occurrence, pretty: true)
  end

  @spec persist(map(), String.t()) :: :ok | {:error, term()}
  def persist(occurrence, workdir) do
    dir = Path.join(workdir, ".nopea")
    etf_dir = Path.join(dir, "occurrences")

    with {:ok, json} <- Jason.encode(occurrence, pretty: true),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(Path.join(dir, "occurrence.json"), json),
         :ok <- File.mkdir_p(etf_dir),
         :ok <-
           File.write(
             Path.join(etf_dir, "#{occurrence["id"]}.etf"),
             :erlang.term_to_binary(occurrence)
           ) do
      :ok
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: ERROR BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_error_block(%{status: :completed}), do: nil

  defp build_error_block(%{status: status, service: service, error: error} = result)
       when status in [:failed, :rolledback] do
    %{
      "code" => error_code(error),
      "what_failed" => "deploy of #{service} (#{result.strategy})",
      "why_it_matters" =>
        "#{service} in #{result.namespace} is not updated — " <>
          status_impact(status, result.strategy)
    }
    |> maybe_add("message", error_message(error))
    |> reject_nils()
  end

  defp build_error_block(_), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: REASONING BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_reasoning_block(%{status: :completed}, _memory), do: nil

  defp build_reasoning_block(%{status: status} = result, memory)
       when status in [:failed, :rolledback] do
    summary = build_summary(result)

    reasoning = %{
      "summary" => summary,
      "confidence" => if(memory && memory[:known], do: 0.8, else: 0.3)
    }

    reasoning
    |> maybe_add("memory_context", build_memory_context(memory))
    |> maybe_add("recommendations", build_recommendations(memory))
  end

  defp build_reasoning_block(_result, _memory), do: nil

  defp build_summary(%{service: service, error: error}) do
    case error do
      {type, _msg} -> "#{service} failed — #{type}"
      nil -> "#{service} failed — cause unknown"
      other -> "#{service} failed — #{inspect(other)}"
    end
  end

  defp build_memory_context(nil), do: nil
  defp build_memory_context(%{failure_patterns: []}), do: nil

  defp build_memory_context(%{failure_patterns: patterns}) when is_list(patterns) do
    Enum.map(patterns, fn p ->
      %{
        "error" => p.error,
        "confidence" => p.confidence,
        "observations" => p.observations
      }
    end)
    |> non_empty()
  end

  defp build_memory_context(_), do: nil

  defp build_recommendations(nil), do: nil

  defp build_recommendations(%{recommendations: recs}) when is_list(recs) do
    non_empty(recs)
  end

  defp build_recommendations(_), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # FALSE PROTOCOL: HISTORY BLOCK
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_history_block(result) do
    steps = build_steps(result)

    %{
      "steps" => steps,
      "duration_ms" => result.duration_ms
    }
  end

  defp build_steps(%{status: :completed} = result) do
    [
      %{
        "description" => "apply manifests",
        "status" => "completed",
        "duration_ms" => result.duration_ms
      }
    ]
    |> maybe_add_verification_step(result)
  end

  defp build_steps(%{status: :failed, error: error} = result) do
    [
      %{
        "description" => "apply manifests",
        "status" => "failed",
        "duration_ms" => result.duration_ms,
        "error" => error_message(error) || "unknown error"
      }
    ]
  end

  defp build_steps(%{status: :rolledback, error: error} = result) do
    [
      %{
        "description" => "apply manifests",
        "status" => "failed",
        "duration_ms" => result.duration_ms,
        "error" => error_message(error) || "unknown error"
      },
      %{"description" => "rollback", "status" => "completed"}
    ]
  end

  defp build_steps(result) do
    [%{"description" => "deploy", "status" => Atom.to_string(result.status)}]
  end

  defp maybe_add_verification_step(steps, %{verified: true}) do
    steps ++ [%{"description" => "post-deploy verification", "status" => "passed"}]
  end

  defp maybe_add_verification_step(steps, _result), do: steps

  # ─────────────────────────────────────────────────────────────────────────────
  # DEPLOY DATA (Domain-Specific Payload)
  # ─────────────────────────────────────────────────────────────────────────────

  defp build_deploy_data(result) do
    %{
      "service" => result.service,
      "namespace" => result.namespace,
      "strategy" => Atom.to_string(result.strategy),
      "manifests_applied" => Map.get(result, :manifests_applied, 0),
      "verified" => Map.get(result, :verified, false)
    }
    |> maybe_add("deploy_id", Map.get(result, :deploy_id))
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # HELPERS
  # ─────────────────────────────────────────────────────────────────────────────

  defp outcome_and_severity(:completed), do: {"completed", "info"}
  defp outcome_and_severity(:failed), do: {"failed", "error"}
  defp outcome_and_severity(:rolledback), do: {"rolledback", "warning"}
  defp outcome_and_severity(_), do: {"failed", "error"}

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

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp non_empty(nil), do: nil
  defp non_empty([]), do: nil
  defp non_empty(list), do: list

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end

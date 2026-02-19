defmodule Nopea.Kulta.RolloutBuilder do
  @moduledoc """
  Builds Kulta Rollout CRD manifests from Nopea deploy specs.

  When Nopea determines a service needs progressive delivery (canary/blue-green),
  it builds a Kulta Rollout instead of applying raw manifests directly.
  Kulta handles the actual traffic shifting, metrics evaluation, and rollback.
  """

  alias Nopea.Deploy.Spec

  @api_version "kulta.io/v1alpha1"
  @kind "Rollout"
  @default_canary_steps [10, 25, 50, 100]

  @spec build(Spec.t(), :canary | :blue_green) :: {:ok, map()} | {:error, term()}
  def build(%Spec{} = spec, strategy) when strategy in [:canary, :blue_green] do
    case extract_deployment(spec.manifests) do
      {:ok, deployment} ->
        rollout = build_rollout(deployment, spec, strategy)
        {:ok, rollout}

      {:error, _} = error ->
        error
    end
  end

  defp build_rollout(deployment, spec, strategy) do
    pod_template = get_in(deployment, ["spec", "template"])
    selector = get_in(deployment, ["spec", "selector"])
    replicas = get_in(deployment, ["spec", "replicas"]) || 1

    %{
      "apiVersion" => @api_version,
      "kind" => @kind,
      "metadata" => %{
        "name" => spec.service,
        "namespace" => spec.namespace,
        "labels" => %{"app.kubernetes.io/managed-by" => "nopea"}
      },
      "spec" => %{
        "replicas" => replicas,
        "selector" => selector,
        "template" => pod_template,
        "strategy" => strategy_config(strategy, spec.service)
      }
    }
  end

  defp strategy_config(:canary, service) do
    %{
      "canary" => %{
        "steps" => Enum.map(@default_canary_steps, fn weight -> %{"setWeight" => weight} end),
        "canaryService" => "#{service}-canary",
        "stableService" => service
      }
    }
  end

  defp strategy_config(:blue_green, service) do
    %{
      "blueGreen" => %{
        "activeService" => service,
        "previewService" => "#{service}-preview"
      }
    }
  end

  @spec extract_deployment([map()]) :: {:ok, map()} | {:error, :no_deployment_found}
  defp extract_deployment(manifests) do
    case Enum.find(manifests, &deployment?/1) do
      nil -> {:error, :no_deployment_found}
      deployment -> {:ok, deployment}
    end
  end

  defp deployment?(%{"kind" => "Deployment"}), do: true
  defp deployment?(_), do: false
end

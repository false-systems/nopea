defmodule Nopea.Strategy.BlueGreen do
  @moduledoc """
  Blue/green deployment strategy.

  Builds a Kulta Rollout CRD with blue/green configuration and applies it.
  Returns {:ok, {applied, :progressing}} to signal that a progressive
  monitor should be started to track the rollout.
  """

  @behaviour Nopea.Strategy

  require Logger

  @impl true
  @spec execute(Nopea.Deploy.Spec.t()) ::
          {:ok, {[map()], :progressing}} | {:error, term()}
  def execute(%Nopea.Deploy.Spec{} = spec) do
    Logger.info("Blue/green deploy",
      service: spec.service,
      namespace: spec.namespace,
      manifest_count: length(spec.manifests)
    )

    with {:ok, rollout} <- Nopea.Kulta.RolloutBuilder.build(spec, :blue_green),
         {:ok, applied} <- k8s_module().apply_manifest(rollout, spec.namespace) do
      {:ok, {[applied], :progressing}}
    end
  end

  defp k8s_module do
    Application.get_env(:nopea, :k8s_module, Nopea.K8s)
  end
end

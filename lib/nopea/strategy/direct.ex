defmodule Nopea.Strategy.Direct do
  @moduledoc """
  Direct deployment strategy.

  Applies all manifests immediately via K8s server-side apply.
  Simplest strategy — wraps Nopea.Applier with connection management.
  """

  @behaviour Nopea.Strategy

  require Logger

  @impl true
  @spec execute(Nopea.Deploy.Spec.t()) :: {:ok, [map()]} | {:error, term()}
  def execute(%Nopea.Deploy.Spec{} = spec) do
    Logger.info(
      "Direct deploy: #{spec.service} → #{spec.namespace} (#{length(spec.manifests)} manifests)"
    )

    k8s_module().apply_manifests(spec.manifests, spec.namespace)
  end

  defp k8s_module do
    Application.get_env(:nopea, :k8s_module, Nopea.K8s)
  end
end

defmodule Nopea.Strategy.Canary do
  @moduledoc """
  Canary deployment strategy.

  Gradually shifts traffic to the new version. Currently applies
  all manifests directly (like Direct strategy), but exposes the
  canary step progression API for future Gateway API HTTPRoute
  weight-based routing integration.

  ## Canary Steps

  Default progression: 10% → 25% → 50% → 75% → 100%
  Each step should be verified before advancing.

  ## Future: Gateway API Integration

  When Gateway API support is added, this strategy will:
  1. Deploy canary Deployment with `-canary` suffix
  2. Create/update HTTPRoute with weight-based backend refs
  3. Step through traffic percentages
  4. Verify health at each step (error rate, latency)
  5. Full cutover or auto-rollback
  """

  @behaviour Nopea.Strategy

  require Logger

  @default_steps [10, 25, 50, 75, 100]

  @impl true
  @spec execute(Nopea.Deploy.Spec.t()) :: {:ok, [map()]} | {:error, term()}
  def execute(%Nopea.Deploy.Spec{} = spec) do
    steps = canary_steps(spec.options)
    Logger.info("Canary deploy: #{spec.service} → #{spec.namespace} (steps: #{inspect(steps)})")

    # Currently applies directly. When Gateway API support is added,
    # this will iterate through canary_steps with verification.
    Nopea.Strategy.Direct.execute(spec)
  end

  @doc """
  Returns the canary step progression percentages.

  Default: [10, 25, 50, 75, 100]
  Override with `canary_steps: [10, 50, 100]` in spec options.
  """
  @spec canary_steps(keyword()) :: [non_neg_integer()]
  def canary_steps(opts) when is_list(opts) do
    Keyword.get(opts, :canary_steps, @default_steps)
  end
end

defmodule Nopea.Strategy.BlueGreen do
  @moduledoc """
  Blue-green deployment strategy.

  Deploys to an inactive slot while the active slot serves traffic,
  then performs an instant cutover. Currently applies manifests
  directly, but exposes the slot management API for future
  Service selector switching.

  ## Slots

  Two parallel environments: `:blue` and `:green`.
  At any time, one is active (serving traffic) and the other is
  the deployment target.

  ## Future: Full Blue-Green

  When Service selector switching is added, this strategy will:
  1. Determine active slot (blue or green)
  2. Deploy to inactive slot (e.g., `-green` suffix)
  3. Verify inactive slot health
  4. Switch Service selector to inactive slot
  5. Inactive becomes active, old active becomes standby
  """

  @behaviour Nopea.Strategy

  require Logger

  @impl true
  @spec execute(Nopea.Deploy.Spec.t()) :: {:ok, [map()]} | {:error, term()}
  def execute(%Nopea.Deploy.Spec{} = spec) do
    active = active_slot(spec.options)
    target = inactive_slot(active)

    Logger.info("Blue-green deploy",
      service: spec.service,
      namespace: spec.namespace,
      active_slot: active,
      target_slot: target
    )

    # Currently applies directly. When Service selector switching
    # is added, this will deploy to the inactive slot and cutover.
    Nopea.Strategy.Direct.execute(spec)
  end

  @doc """
  Returns the currently active slot.
  Default: `:blue`
  """
  @spec active_slot(keyword()) :: :blue | :green
  def active_slot(opts) when is_list(opts) do
    Keyword.get(opts, :active_slot, :blue)
  end

  @doc """
  Returns the inactive slot (deployment target).
  """
  @spec inactive_slot(:blue | :green) :: :green | :blue
  def inactive_slot(:blue), do: :green
  def inactive_slot(:green), do: :blue
end

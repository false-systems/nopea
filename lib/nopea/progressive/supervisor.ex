defmodule Nopea.Progressive.Supervisor do
  @moduledoc """
  DynamicSupervisor for Progressive.Monitor processes.

  One Monitor per active rollout, started when a canary or
  blue_green deploy returns :progressing.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_monitor(String.t(), Nopea.Deploy.Spec.t(), :canary | :blue_green) ::
          {:ok, pid()} | {:error, term()}
  def start_monitor(deploy_id, spec, strategy) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Nopea.Progressive.Monitor, {deploy_id, spec, strategy}}
    )
  end
end

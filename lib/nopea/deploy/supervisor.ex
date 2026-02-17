defmodule Nopea.Deploy.Supervisor do
  @moduledoc """
  DynamicSupervisor for deploy worker processes.

  Each deployment gets its own short-lived worker process
  that manages the deploy lifecycle.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_deploy(map()) :: {:ok, pid()} | {:error, term()}
  def start_deploy(deploy_spec) do
    DynamicSupervisor.start_child(__MODULE__, {Nopea.Deploy.Worker, deploy_spec})
  end
end

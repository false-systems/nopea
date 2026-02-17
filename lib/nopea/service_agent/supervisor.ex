defmodule Nopea.ServiceAgent.Supervisor do
  @moduledoc """
  DynamicSupervisor for per-service agent processes.

  Unlike Deploy.Supervisor (temporary workers), agents are permanent —
  they survive individual deploy failures and maintain service state.
  """

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_agent(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_agent(service) do
    DynamicSupervisor.start_child(__MODULE__, {Nopea.ServiceAgent, service})
  end
end

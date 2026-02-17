defmodule Nopea.Deploy.Worker do
  @moduledoc """
  Short-lived GenServer managing a single deployment lifecycle.

  Flow: context → strategy → execute → verify → record
  """

  use GenServer, restart: :temporary
  require Logger

  def start_link(deploy_spec) do
    GenServer.start_link(__MODULE__, deploy_spec)
  end

  @impl true
  def init(spec) do
    send(self(), :execute)
    {:ok, %{spec: spec, status: :pending, started_at: System.monotonic_time()}}
  end

  @impl true
  def handle_info(:execute, state) do
    result = Nopea.Deploy.execute(state.spec)
    {:stop, :normal, %{state | status: result_status(result)}}
  end

  defp result_status({:ok, _}), do: :completed
  defp result_status({:error, _}), do: :failed
  defp result_status(_), do: :unknown
end

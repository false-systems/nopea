defmodule Nopea.SYKLI.Target do
  @moduledoc """
  SYKLI target implementation for Nopea deployments.

  Allows SYKLI pipelines to trigger Nopea deployments as tasks.
  Implements the core SYKLI target callbacks without requiring
  SYKLI as a dependency — compatible by interface, not coupling.

  ## Usage from SYKLI

      targets:
        deploy:
          type: nopea
          namespace: production

      tasks:
        deploy:
          target: deploy
          service: api-gateway
          manifests: manifests/
          strategy: canary
  """

  require Logger

  defmodule State do
    @moduledoc false
    defstruct [:namespace]
  end

  @spec name() :: String.t()
  def name, do: "nopea"

  @spec available?() :: {:ok, map()} | {:error, term()}
  def available? do
    {:ok,
     %{
       name: "nopea",
       version: Application.spec(:nopea, :vsn) |> to_string(),
       capabilities: [:deploy, :context, :history, :memory]
     }}
  end

  @spec setup(keyword()) :: {:ok, State.t()} | {:error, term()}
  def setup(opts) do
    namespace = Keyword.get(opts, :namespace, "default")
    {:ok, %State{namespace: namespace}}
  end

  @spec teardown(State.t()) :: :ok
  def teardown(%State{}), do: :ok

  @spec run_task(map(), State.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def run_task(task, %State{} = state, _opts) do
    spec = %Nopea.Deploy.Spec{
      service: Map.fetch!(task, :service),
      namespace: Map.get(task, :namespace, state.namespace),
      manifests: Map.get(task, :manifests, []),
      strategy: Map.get(task, :strategy)
    }

    result = Nopea.Deploy.run(spec)

    case result.status do
      :completed -> {:ok, result}
      :failed -> {:error, result.error}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end

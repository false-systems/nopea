defmodule Nopea.SYKLI.TargetBehaviour do
  @moduledoc """
  Behaviour defining the SYKLI target interface for Nopea deployments.

  Any module implementing this behaviour can serve as a SYKLI pipeline target,
  providing deploy capabilities through the standard SYKLI task execution model.
  """

  @doc """
  Returns the target name identifier.
  """
  @callback name() :: String.t()

  @doc """
  Checks whether this target is available and returns capability metadata.
  """
  @callback available?() :: {:ok, map()} | {:error, term()}

  @doc """
  Initializes the target with the given options, returning target state.
  """
  @callback setup(keyword()) :: {:ok, term()} | {:error, term()}

  @doc """
  Tears down the target, releasing any resources held in state.
  """
  @callback teardown(term()) :: :ok

  @doc """
  Executes a task against this target with the given state and options.
  """
  @callback run_task(map(), term(), keyword()) :: {:ok, term()} | {:error, term()}
end

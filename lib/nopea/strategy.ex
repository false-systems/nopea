defmodule Nopea.Strategy do
  @moduledoc """
  Behaviour for deployment strategies.

  All strategies take a DeploySpec and return either
  {:ok, applied_resources} or {:error, reason}.
  """

  @callback execute(Nopea.Deploy.Spec.t()) :: {:ok, [map()]} | {:error, term()}
end

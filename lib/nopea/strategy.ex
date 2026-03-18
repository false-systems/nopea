defmodule Nopea.Strategy do
  @moduledoc """
  Behaviour for deployment strategies.

  All strategies take a DeploySpec and return either
  {:ok, applied_resources}, {:ok, {applied_resources, :progressing}}, or {:error, reason}.

  Progressive strategies (canary, blue_green) return the :progressing tuple
  to indicate that a rollout monitor should be started.
  """

  @callback execute(Nopea.Deploy.Spec.t()) ::
              {:ok, [map()]} | {:ok, {[map()], :progressing}} | {:error, term()}
end

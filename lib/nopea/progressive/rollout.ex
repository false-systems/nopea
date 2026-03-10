defmodule Nopea.Progressive.Rollout do
  @moduledoc """
  Tracks the state of an active progressive delivery rollout.

  Created when a canary or blue_green deploy starts, updated
  as the Monitor polls the Kulta Rollout CRD status.
  """

  @type phase :: :progressing | :promoted | :degraded | :paused | :failed | :completed

  @type t :: %__MODULE__{
          deploy_id: String.t(),
          service: String.t(),
          namespace: String.t(),
          strategy: :canary | :blue_green,
          phase: phase(),
          current_step: non_neg_integer(),
          total_steps: non_neg_integer(),
          started_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @enforce_keys [:deploy_id, :service, :namespace, :strategy, :phase]
  defstruct [
    :deploy_id,
    :service,
    :namespace,
    :strategy,
    phase: :progressing,
    current_step: 0,
    total_steps: 0,
    started_at: nil,
    updated_at: nil
  ]

  @spec new(String.t(), String.t(), String.t(), :canary | :blue_green) :: t()
  def new(deploy_id, service, namespace, strategy) do
    now = DateTime.utc_now()

    %__MODULE__{
      deploy_id: deploy_id,
      service: service,
      namespace: namespace,
      strategy: strategy,
      phase: :progressing,
      started_at: now,
      updated_at: now
    }
  end
end

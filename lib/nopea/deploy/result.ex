defmodule Nopea.Deploy.Result do
  @moduledoc """
  Deployment result struct.

  Captures the outcome of a deployment including timing,
  verification status, and any errors.
  """

  @type t :: %__MODULE__{
          deploy_id: String.t(),
          service: String.t(),
          namespace: String.t(),
          status: :completed | :failed | :rolledback,
          strategy: atom(),
          manifest_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          verified: boolean(),
          error: term() | nil,
          applied_resources: [map()],
          timestamp: DateTime.t()
        }

  defstruct [
    :deploy_id,
    :service,
    :namespace,
    :status,
    :strategy,
    :error,
    manifest_count: 0,
    duration_ms: 0,
    verified: false,
    applied_resources: [],
    timestamp: nil
  ]

  @spec success(String.t(), Nopea.Deploy.Spec.t(), atom(), [map()], non_neg_integer(), boolean()) ::
          t()
  def success(deploy_id, spec, strategy, applied, duration_ms, verified) do
    %__MODULE__{
      deploy_id: deploy_id,
      service: spec.service,
      namespace: spec.namespace,
      status: :completed,
      strategy: strategy,
      manifest_count: length(spec.manifests),
      duration_ms: duration_ms,
      verified: verified,
      applied_resources: applied,
      timestamp: DateTime.utc_now()
    }
  end

  @spec failure(String.t(), Nopea.Deploy.Spec.t(), atom(), term(), non_neg_integer()) :: t()
  def failure(deploy_id, spec, strategy, error, duration_ms) do
    %__MODULE__{
      deploy_id: deploy_id,
      service: spec.service,
      namespace: spec.namespace,
      status: :failed,
      strategy: strategy,
      manifest_count: length(spec.manifests),
      duration_ms: duration_ms,
      error: error,
      timestamp: DateTime.utc_now()
    }
  end
end

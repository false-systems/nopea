defmodule Nopea.Deploy.Result do
  @moduledoc """
  Deployment result struct.

  Captures the outcome of a deployment including timing,
  verification status, and any errors.
  """

  @type strategy :: :direct | :canary | :blue_green

  @type t :: %__MODULE__{
          deploy_id: String.t(),
          service: String.t(),
          namespace: String.t(),
          status: :completed | :failed | :rolledback | :progressing,
          strategy: strategy(),
          manifest_count: non_neg_integer(),
          duration_ms: non_neg_integer(),
          verified: boolean(),
          error: term() | nil,
          applied_resources: [map()],
          timestamp: DateTime.t()
        }

  @enforce_keys [:deploy_id, :service, :namespace, :status, :strategy]
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

  @spec success(
          String.t(),
          Nopea.Deploy.Spec.t(),
          strategy(),
          [map()],
          non_neg_integer(),
          boolean()
        ) ::
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

  @spec failure(String.t(), Nopea.Deploy.Spec.t(), strategy(), term(), non_neg_integer()) :: t()
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

  @spec progressing(String.t(), Nopea.Deploy.Spec.t(), strategy(), [map()], non_neg_integer()) ::
          t()
  def progressing(deploy_id, spec, strategy, applied, duration_ms) do
    %__MODULE__{
      deploy_id: deploy_id,
      service: spec.service,
      namespace: spec.namespace,
      status: :progressing,
      strategy: strategy,
      manifest_count: length(spec.manifests),
      duration_ms: duration_ms,
      applied_resources: applied,
      timestamp: DateTime.utc_now()
    }
  end

  @spec rolledback(String.t(), Nopea.Deploy.Spec.t(), strategy(), term(), non_neg_integer()) ::
          t()
  def rolledback(deploy_id, spec, strategy, error, duration_ms) do
    %__MODULE__{
      deploy_id: deploy_id,
      service: spec.service,
      namespace: spec.namespace,
      status: :rolledback,
      strategy: strategy,
      manifest_count: length(spec.manifests),
      duration_ms: duration_ms,
      error: error,
      timestamp: DateTime.utc_now()
    }
  end
end

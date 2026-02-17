defmodule Nopea.Metrics do
  @moduledoc """
  Telemetry metrics for deployment operations.

  Exposes Prometheus-compatible metrics for:
  - Deploy operations (duration, success/failure)
  - Memory queries
  - Drift verification
  - Active deploys
  """

  import Telemetry.Metrics

  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # Deploy metrics
      distribution("nopea.deploy.duration",
        unit: {:native, :second},
        description: "Deploy operation duration",
        tags: [:service, :strategy],
        reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60]]
      ),
      counter("nopea.deploy.total",
        event_name: [:nopea, :deploy, :stop],
        description: "Total deploy operations",
        tags: [:service, :strategy]
      ),
      counter("nopea.deploy.error.total",
        event_name: [:nopea, :deploy, :error],
        description: "Total deploy errors",
        tags: [:service, :error]
      ),

      # Memory metrics
      distribution("nopea.memory.query.duration",
        unit: {:native, :second},
        description: "Memory context query duration",
        tags: [:service]
      ),

      # Drift verification
      counter("nopea.verify.drift",
        description: "Drift verification events",
        tags: [:service],
        measurement: :count
      ),

      # Active deploys
      last_value("nopea.deploys.active",
        description: "Number of active deploys",
        measurement: :count
      )
    ]
  end

  @spec emit_deploy_start(map()) :: integer()
  def emit_deploy_start(metadata) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:nopea, :deploy, :start],
      %{system_time: System.system_time()},
      metadata
    )

    start_time
  end

  @spec emit_deploy_error(integer(), map()) :: :ok
  def emit_deploy_error(start_time, metadata) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:nopea, :deploy, :error],
      %{duration: duration},
      metadata
    )

    :ok
  end
end

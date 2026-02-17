defmodule Nopea.MetricsTest do
  use ExUnit.Case, async: false

  alias Nopea.Metrics

  describe "metrics/0" do
    test "returns list of telemetry metrics definitions" do
      metrics = Metrics.metrics()

      assert is_list(metrics)
      assert [_ | _] = metrics

      metric_names = Enum.map(metrics, & &1.name)

      assert [:nopea, :deploy, :duration] in metric_names
      assert [:nopea, :deploy, :total] in metric_names
      assert [:nopea, :deploys, :active] in metric_names
    end
  end

  describe "emit_deploy_start/1" do
    test "emits telemetry event for deploy start" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :deploy, :start]
        ])

      Metrics.emit_deploy_start(%{service: "test-svc", strategy: :direct})

      assert_receive {[:nopea, :deploy, :start], ^ref, %{system_time: _},
                      %{service: "test-svc", strategy: :direct}}
    end
  end

  describe "emit_deploy_stop/2" do
    test "emits telemetry event for deploy stop with duration" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :deploy, :stop]
        ])

      start_time = System.monotonic_time()
      Process.sleep(10)
      Metrics.emit_deploy_stop(start_time, %{service: "test-svc", strategy: :direct})

      assert_receive {[:nopea, :deploy, :stop], ^ref, %{duration: duration},
                      %{service: "test-svc", strategy: :direct}}

      assert duration > 0
    end
  end

  describe "emit_deploy_error/2" do
    test "emits telemetry event for deploy error" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :deploy, :error]
        ])

      start_time = System.monotonic_time()
      Metrics.emit_deploy_error(start_time, %{service: "test-svc", error: :timeout})

      assert_receive {[:nopea, :deploy, :error], ^ref, %{duration: _},
                      %{service: "test-svc", error: :timeout}}
    end
  end

  describe "set_active_deploys/1" do
    test "emits telemetry event for active deploy count" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:nopea, :deploys, :active]
        ])

      Metrics.set_active_deploys(3)

      assert_receive {[:nopea, :deploys, :active], ^ref, %{count: 3}, %{}}
    end
  end
end

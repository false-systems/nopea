defmodule Nopea.DeployTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Deploy
  alias Nopea.Deploy.Spec

  setup :verify_on_exit!

  setup do
    # Stub K8s mock to fall through to real implementation (works for empty manifests)
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    # Start Memory for context tracking
    start_supervised!({Nopea.Memory, []})
    # Start Cache for state recording
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "run/1 with empty manifests" do
    test "succeeds with direct strategy" do
      spec = %Spec{
        service: "test-svc",
        namespace: "default",
        manifests: [],
        strategy: :direct
      }

      result = Deploy.run(spec)

      assert result.status == :completed
      assert result.service == "test-svc"
      assert result.namespace == "default"
      assert result.strategy == :direct
      assert result.manifest_count == 0
      assert result.duration_ms >= 0
      assert is_binary(result.deploy_id)
    end

    test "records deploy in memory" do
      spec = %Spec{
        service: "memory-test-svc",
        namespace: "default",
        manifests: [],
        strategy: :direct
      }

      Deploy.run(spec)

      # Memory.record_deploy is a cast, give it time
      Process.sleep(50)

      ctx = Nopea.Memory.get_deploy_context("memory-test-svc", "default")
      assert ctx.known == true
    end

    test "records deploy in cache" do
      spec = %Spec{
        service: "cache-test-svc",
        namespace: "default",
        manifests: [],
        strategy: :direct
      }

      result = Deploy.run(spec)

      # Cache is synchronous
      assert {:ok, _} = Nopea.Cache.get_deployment("cache-test-svc", result.deploy_id)
      assert {:ok, state} = Nopea.Cache.get_service_state("cache-test-svc")
      assert state.status == :completed
    end

    test "uses explicit strategy when provided" do
      spec = %Spec{
        service: "svc",
        namespace: "default",
        manifests: [],
        strategy: :blue_green
      }

      result = Deploy.run(spec)
      assert result.strategy == :blue_green
    end
  end

  describe "strategy selection" do
    test "auto-selects canary when memory shows failure patterns" do
      # First, create a failure pattern in memory
      Nopea.Memory.record_deploy(%{
        service: "risky-svc",
        namespace: "prod",
        status: :failed,
        error: "crash"
      })

      Process.sleep(50)

      # Now deploy without explicit strategy — should auto-select canary
      spec = %Spec{
        service: "risky-svc",
        namespace: "prod",
        manifests: [],
        strategy: nil
      }

      result = Deploy.run(spec)
      # With failure patterns > 0.15 confidence, should pick canary
      assert result.strategy == :canary
    end

    test "uses direct when no failure patterns" do
      spec = %Spec{
        service: "clean-svc",
        namespace: "default",
        manifests: [],
        strategy: nil
      }

      result = Deploy.run(spec)
      assert result.strategy == :direct
    end
  end

  describe "execute/1" do
    test "returns {:ok, result} on success" do
      spec_map = %{service: "exec-svc", namespace: "default", manifests: [], strategy: :direct}

      assert {:ok, result} = Deploy.execute(spec_map)
      assert result.status == :completed
    end
  end
end

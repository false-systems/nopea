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

    test "unknown strategy falls back to direct" do
      spec = %Spec{
        service: "svc",
        namespace: "default",
        manifests: [],
        strategy: :rolling
      }

      result = Deploy.run(spec)
      assert result.strategy == :direct
    end
  end

  describe "strategy selection" do
    test "always uses direct when no explicit strategy" do
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

  describe "Kulta strategies" do
    test "canary strategy builds and applies Rollout CRD" do
      deployment = Nopea.Test.Factory.sample_deployment_manifest("canary-svc", "prod")

      Nopea.K8sMock
      |> expect(:apply_manifest, fn manifest, "prod" ->
        assert manifest["apiVersion"] == "kulta.io/v1alpha1"
        assert manifest["kind"] == "Rollout"
        assert manifest["spec"]["strategy"]["canary"] != nil
        {:ok, manifest}
      end)

      spec = %Spec{
        service: "canary-svc",
        namespace: "prod",
        manifests: [deployment],
        strategy: :canary
      }

      result = Deploy.run(spec)
      assert result.status == :completed
      assert result.strategy == :canary
    end

    test "blue_green strategy builds and applies Rollout CRD" do
      deployment = Nopea.Test.Factory.sample_deployment_manifest("bg-svc", "staging")

      Nopea.K8sMock
      |> expect(:apply_manifest, fn manifest, "staging" ->
        assert manifest["kind"] == "Rollout"
        assert manifest["spec"]["strategy"]["blueGreen"] != nil
        {:ok, manifest}
      end)

      spec = %Spec{
        service: "bg-svc",
        namespace: "staging",
        manifests: [deployment],
        strategy: :blue_green
      }

      result = Deploy.run(spec)
      assert result.status == :completed
      assert result.strategy == :blue_green
    end

    test "canary fails gracefully when no Deployment in manifests" do
      service_manifest = Nopea.Test.Factory.sample_service_manifest("no-deploy-svc")

      spec = %Spec{
        service: "no-deploy-svc",
        namespace: "default",
        manifests: [service_manifest],
        strategy: :canary
      }

      result = Deploy.run(spec)
      assert result.status == :failed
      assert result.error == :no_deployment_found
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

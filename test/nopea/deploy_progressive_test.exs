defmodule Nopea.DeployProgressiveTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Deploy
  alias Nopea.Deploy.Spec
  alias Nopea.Test.Factory

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp_dir} do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)

    Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ ->
      {:error, :not_found}
    end)

    Mox.stub(Nopea.K8sMock, :patch_resource, fn _, _, _, _, _ ->
      {:ok, %{}}
    end)

    start_supervised!({Nopea.Memory, workdir: tmp_dir})
    start_supervised!(Nopea.Cache)
    start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
    start_supervised!(Nopea.Progressive.Supervisor)
    :ok
  end

  describe "canary deploy returns :progressing" do
    test "canary deploy returns progressing status and starts monitor" do
      deployment = Factory.sample_deployment_manifest("canary-svc", "default")

      Mox.expect(Nopea.K8sMock, :apply_manifest, fn manifest, "default" ->
        assert manifest["kind"] == "Rollout"
        assert manifest["metadata"]["name"] == "canary-svc"
        {:ok, manifest}
      end)

      spec = %Spec{
        service: "canary-svc",
        namespace: "default",
        manifests: [deployment],
        strategy: :canary
      }

      result = Deploy.run(spec)

      assert result.status == :progressing
      assert result.strategy == :canary
      assert result.service == "canary-svc"
      assert is_binary(result.deploy_id)

      # Monitor should be running
      assert {:ok, rollout} = Nopea.Progressive.Monitor.status(result.deploy_id)
      assert rollout.phase == :progressing
      assert rollout.strategy == :canary
    end
  end

  describe "blue_green deploy returns :progressing" do
    test "blue_green deploy returns progressing status" do
      deployment = Factory.sample_deployment_manifest("bg-svc", "default")

      Mox.expect(Nopea.K8sMock, :apply_manifest, fn manifest, "default" ->
        assert manifest["kind"] == "Rollout"
        {:ok, manifest}
      end)

      spec = %Spec{
        service: "bg-svc",
        namespace: "default",
        manifests: [deployment],
        strategy: :blue_green
      }

      result = Deploy.run(spec)

      assert result.status == :progressing
      assert result.strategy == :blue_green
    end
  end

  describe "direct deploy still returns :completed" do
    test "direct deploy is unaffected" do
      spec = %Spec{
        service: "direct-svc",
        namespace: "default",
        manifests: [],
        strategy: :direct
      }

      result = Deploy.run(spec)
      assert result.status == :completed
      assert result.strategy == :direct
    end
  end

  describe "canary deploy fails without Deployment manifest" do
    test "returns :failed with :no_deployment_found" do
      spec = %Spec{
        service: "no-deploy-svc",
        namespace: "default",
        manifests: [Factory.sample_configmap_manifest("cfg", "default")],
        strategy: :canary
      }

      result = Deploy.run(spec)
      assert result.status == :failed
      assert result.error == :no_deployment_found
    end
  end
end

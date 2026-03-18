defmodule Nopea.Strategy.BlueGreenTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.Deploy.Spec
  alias Nopea.Strategy.BlueGreen
  alias Nopea.Test.Factory

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    :ok
  end

  describe "execute/1" do
    test "builds blue_green rollout and returns progressing" do
      deployment = Factory.sample_deployment_manifest("api", "production")

      applied_rollout = %{
        "apiVersion" => "kulta.io/v1alpha1",
        "kind" => "Rollout",
        "metadata" => %{"name" => "api", "namespace" => "production"}
      }

      Nopea.K8sMock
      |> expect(:apply_manifest, fn rollout, "production" ->
        assert rollout["kind"] == "Rollout"
        assert rollout["apiVersion"] == "kulta.io/v1alpha1"
        assert rollout["metadata"]["name"] == "api"
        assert rollout["spec"]["strategy"]["blueGreen"] != nil
        {:ok, applied_rollout}
      end)

      spec = %Spec{
        service: "api",
        namespace: "production",
        manifests: [deployment]
      }

      assert {:ok, {[^applied_rollout], :progressing}} = BlueGreen.execute(spec)
    end

    test "returns error when no deployment manifest found" do
      configmap = Factory.sample_configmap_manifest("cfg", "default", %{"key" => "val"})

      spec = %Spec{
        service: "api",
        namespace: "default",
        manifests: [configmap]
      }

      assert {:error, :no_deployment_found} = BlueGreen.execute(spec)
    end

    test "propagates K8s apply errors" do
      deployment = Factory.sample_deployment_manifest("api", "default")

      Nopea.K8sMock
      |> expect(:apply_manifest, fn _rollout, "default" ->
        {:error, :timeout}
      end)

      spec = %Spec{
        service: "api",
        namespace: "default",
        manifests: [deployment]
      }

      assert {:error, :timeout} = BlueGreen.execute(spec)
    end
  end
end

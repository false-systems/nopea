defmodule Nopea.Strategy.CanaryTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.Deploy.Spec
  alias Nopea.Strategy.Canary
  alias Nopea.Test.Factory

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    :ok
  end

  describe "execute/1" do
    test "builds canary rollout and returns progressing" do
      deployment = Factory.sample_deployment_manifest("web", "staging")

      applied_rollout = %{
        "apiVersion" => "kulta.io/v1alpha1",
        "kind" => "Rollout",
        "metadata" => %{"name" => "web", "namespace" => "staging"}
      }

      Nopea.K8sMock
      |> expect(:apply_manifest, fn rollout, "staging" ->
        assert rollout["kind"] == "Rollout"
        assert rollout["apiVersion"] == "kulta.io/v1alpha1"
        assert rollout["metadata"]["name"] == "web"
        assert rollout["spec"]["strategy"]["canary"] != nil
        {:ok, applied_rollout}
      end)

      spec = %Spec{
        service: "web",
        namespace: "staging",
        manifests: [deployment]
      }

      assert {:ok, {[^applied_rollout], :progressing}} = Canary.execute(spec)
    end

    test "returns error when no deployment manifest found" do
      configmap = Factory.sample_configmap_manifest("cfg", "default", %{"key" => "val"})

      spec = %Spec{
        service: "web",
        namespace: "default",
        manifests: [configmap]
      }

      assert {:error, :no_deployment_found} = Canary.execute(spec)
    end

    test "propagates K8s apply errors" do
      deployment = Factory.sample_deployment_manifest("web", "default")

      Nopea.K8sMock
      |> expect(:apply_manifest, fn _rollout, "default" ->
        {:error, :forbidden}
      end)

      spec = %Spec{
        service: "web",
        namespace: "default",
        manifests: [deployment]
      }

      assert {:error, :forbidden} = Canary.execute(spec)
    end
  end
end

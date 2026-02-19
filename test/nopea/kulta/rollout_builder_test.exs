defmodule Nopea.Kulta.RolloutBuilderTest do
  use ExUnit.Case, async: true

  alias Nopea.Kulta.RolloutBuilder
  alias Nopea.Deploy.Spec

  @deployment %{
    "apiVersion" => "apps/v1",
    "kind" => "Deployment",
    "metadata" => %{"name" => "api-gw", "namespace" => "production"},
    "spec" => %{
      "replicas" => 3,
      "selector" => %{"matchLabels" => %{"app" => "api-gw"}},
      "template" => %{
        "metadata" => %{"labels" => %{"app" => "api-gw"}},
        "spec" => %{
          "containers" => [%{"name" => "app", "image" => "api-gw:v2"}]
        }
      }
    }
  }

  @service_manifest %{
    "apiVersion" => "v1",
    "kind" => "Service",
    "metadata" => %{"name" => "api-gw"},
    "spec" => %{"selector" => %{"app" => "api-gw"}, "ports" => [%{"port" => 80}]}
  }

  describe "build/2 canary" do
    test "builds canary Rollout from spec with Deployment" do
      spec = %Spec{
        service: "api-gw",
        namespace: "production",
        manifests: [@deployment, @service_manifest]
      }

      assert {:ok, rollout} = RolloutBuilder.build(spec, :canary)

      assert rollout["apiVersion"] == "kulta.io/v1alpha1"
      assert rollout["kind"] == "Rollout"
      assert rollout["metadata"]["name"] == "api-gw"
      assert rollout["metadata"]["namespace"] == "production"
    end

    test "canary config has steps and service names" do
      spec = %Spec{
        service: "api-gw",
        namespace: "production",
        manifests: [@deployment]
      }

      {:ok, rollout} = RolloutBuilder.build(spec, :canary)
      canary = rollout["spec"]["strategy"]["canary"]

      assert is_list(canary["steps"])
      assert length(canary["steps"]) == 4
      assert hd(canary["steps"]) == %{"setWeight" => 10}
      assert List.last(canary["steps"]) == %{"setWeight" => 100}
      assert canary["canaryService"] == "api-gw-canary"
      assert canary["stableService"] == "api-gw"
    end

    test "preserves pod template and selector from Deployment" do
      spec = %Spec{
        service: "api-gw",
        namespace: "production",
        manifests: [@deployment]
      }

      {:ok, rollout} = RolloutBuilder.build(spec, :canary)

      assert rollout["spec"]["template"] == @deployment["spec"]["template"]
      assert rollout["spec"]["selector"] == @deployment["spec"]["selector"]
      assert rollout["spec"]["replicas"] == 3
    end
  end

  describe "build/2 blue_green" do
    test "builds blue-green Rollout from spec" do
      spec = %Spec{
        service: "payment-svc",
        namespace: "staging",
        manifests: [@deployment]
      }

      {:ok, rollout} = RolloutBuilder.build(spec, :blue_green)
      bg = rollout["spec"]["strategy"]["blueGreen"]

      assert bg["activeService"] == "payment-svc"
      assert bg["previewService"] == "payment-svc-preview"
    end
  end

  describe "build/2 errors" do
    test "returns error when no Deployment in manifests" do
      spec = %Spec{
        service: "configmap-only",
        namespace: "default",
        manifests: [@service_manifest]
      }

      assert {:error, :no_deployment_found} = RolloutBuilder.build(spec, :canary)
    end

    test "returns error for empty manifests" do
      spec = %Spec{
        service: "empty",
        namespace: "default",
        manifests: []
      }

      assert {:error, :no_deployment_found} = RolloutBuilder.build(spec, :blue_green)
    end
  end

  describe "metadata" do
    test "adds managed-by label" do
      spec = %Spec{
        service: "labeled-svc",
        namespace: "default",
        manifests: [@deployment]
      }

      {:ok, rollout} = RolloutBuilder.build(spec, :canary)

      assert rollout["metadata"]["labels"]["app.kubernetes.io/managed-by"] == "nopea"
    end
  end
end

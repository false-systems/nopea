defmodule Nopea.Strategy.CanaryTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.Strategy.Canary
  alias Nopea.Deploy.Spec

  setup :verify_on_exit!

  @spec_with_manifests %Spec{
    service: "api-gateway",
    namespace: "production",
    strategy: :canary,
    manifests: [
      %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{"name" => "api-gateway", "namespace" => "production"},
        "spec" => %{
          "replicas" => 3,
          "selector" => %{"matchLabels" => %{"app" => "api-gateway"}},
          "template" => %{
            "metadata" => %{"labels" => %{"app" => "api-gateway"}},
            "spec" => %{"containers" => [%{"name" => "app", "image" => "api:v2"}]}
          }
        }
      }
    ],
    options: []
  }

  @empty_spec %Spec{
    service: "empty-svc",
    namespace: "default",
    strategy: :canary,
    manifests: [],
    options: []
  }

  describe "execute/1" do
    test "falls back to direct for empty manifests" do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn [], _ -> {:ok, []} end)

      assert {:ok, []} = Canary.execute(@empty_spec)
    end

    test "applies manifests via direct strategy" do
      manifests = @spec_with_manifests.manifests

      Nopea.K8sMock
      |> expect(:apply_manifests, fn ^manifests, "production" -> {:ok, manifests} end)

      assert {:ok, applied} = Canary.execute(@spec_with_manifests)
      assert length(applied) == 1
    end

    test "returns error when apply fails" do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _, _ -> {:error, :connection_refused} end)

      assert {:error, :connection_refused} = Canary.execute(@spec_with_manifests)
    end
  end

  describe "canary_steps/1" do
    test "returns default progression steps" do
      steps = Canary.canary_steps([])

      assert is_list(steps)
      assert steps != []
      assert hd(steps) < 100
      assert List.last(steps) == 100
    end

    test "custom steps override defaults" do
      steps = Canary.canary_steps(canary_steps: [10, 50, 100])

      assert steps == [10, 50, 100]
    end
  end
end

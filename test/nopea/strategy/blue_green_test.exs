defmodule Nopea.Strategy.BlueGreenTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.Strategy.BlueGreen
  alias Nopea.Deploy.Spec

  setup :verify_on_exit!

  @spec_with_manifests %Spec{
    service: "payment-svc",
    namespace: "production",
    strategy: :blue_green,
    manifests: [
      %{
        "apiVersion" => "apps/v1",
        "kind" => "Deployment",
        "metadata" => %{"name" => "payment-svc", "namespace" => "production"},
        "spec" => %{
          "selector" => %{"matchLabels" => %{"app" => "payment-svc"}},
          "template" => %{
            "spec" => %{"containers" => [%{"name" => "app", "image" => "payment:v3"}]}
          }
        }
      }
    ],
    options: []
  }

  describe "execute/1" do
    test "applies manifests via direct strategy" do
      manifests = @spec_with_manifests.manifests

      Nopea.K8sMock
      |> expect(:apply_manifests, fn ^manifests, "production" -> {:ok, manifests} end)

      assert {:ok, applied} = BlueGreen.execute(@spec_with_manifests)
      assert length(applied) == 1
    end

    test "returns error when apply fails" do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _, _ -> {:error, :forbidden} end)

      assert {:error, :forbidden} = BlueGreen.execute(@spec_with_manifests)
    end
  end

  describe "active_slot/1" do
    test "returns :blue by default" do
      assert BlueGreen.active_slot([]) == :blue
    end

    test "returns configured active slot" do
      assert BlueGreen.active_slot(active_slot: :green) == :green
    end
  end

  describe "inactive_slot/1" do
    test "returns opposite of active" do
      assert BlueGreen.inactive_slot(:blue) == :green
      assert BlueGreen.inactive_slot(:green) == :blue
    end
  end
end

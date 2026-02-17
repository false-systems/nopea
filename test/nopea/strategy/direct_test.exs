defmodule Nopea.Strategy.DirectTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.Deploy.Spec
  alias Nopea.Strategy.Direct

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    :ok
  end

  describe "execute/1" do
    test "succeeds with empty manifests" do
      spec = %Spec{
        service: "test-svc",
        namespace: "default",
        manifests: []
      }

      assert {:ok, []} = Direct.execute(spec)
    end

    test "delegates to K8s apply_manifests" do
      manifests = [%{"kind" => "ConfigMap", "metadata" => %{"name" => "test"}}]

      Nopea.K8sMock
      |> expect(:apply_manifests, fn ^manifests, "staging" -> {:ok, manifests} end)

      spec = %Spec{
        service: "test-svc",
        namespace: "staging",
        manifests: manifests
      }

      assert {:ok, ^manifests} = Direct.execute(spec)
    end

    test "propagates errors from K8s" do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _, _ -> {:error, :forbidden} end)

      spec = %Spec{
        service: "test-svc",
        namespace: "default",
        manifests: [%{"kind" => "Deployment"}]
      }

      assert {:error, :forbidden} = Direct.execute(spec)
    end
  end
end

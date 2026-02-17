defmodule Nopea.SYKLI.TargetTest do
  use ExUnit.Case, async: true

  import Mox

  alias Nopea.SYKLI.Target

  setup :verify_on_exit!

  describe "name/0" do
    test "returns nopea" do
      assert Target.name() == "nopea"
    end
  end

  describe "available?/0" do
    test "returns ok with capabilities" do
      assert {:ok, info} = Target.available?()
      assert info.name == "nopea"
      assert is_list(info.capabilities)
      assert :deploy in info.capabilities
    end
  end

  describe "setup/1" do
    test "returns state with defaults" do
      assert {:ok, state} = Target.setup([])
      assert state.namespace == "default"
    end

    test "accepts namespace option" do
      assert {:ok, state} = Target.setup(namespace: "production")
      assert state.namespace == "production"
    end
  end

  describe "teardown/1" do
    test "returns ok" do
      {:ok, state} = Target.setup([])
      assert :ok = Target.teardown(state)
    end
  end

  describe "run_task/3" do
    setup do
      Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
      {:ok, state} = Target.setup([])
      %{state: state}
    end

    test "deploys from task spec with manifests", %{state: state} do
      task = %{
        name: "deploy-api",
        service: "api-gateway",
        manifests: [],
        strategy: :direct
      }

      assert {:ok, result} = Target.run_task(task, state, [])
      assert result.status == :completed
      assert result.service == "api-gateway"
    end

    test "deploys with specified namespace", %{state: _state} do
      {:ok, state} = Target.setup(namespace: "staging")

      task = %{
        name: "deploy-api",
        service: "api-gateway",
        manifests: [],
        strategy: :direct
      }

      assert {:ok, result} = Target.run_task(task, state, [])
      assert result.namespace == "staging"
    end

    test "returns error on deploy failure", %{state: state} do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _, _ -> {:error, :forbidden} end)

      task = %{
        name: "deploy-api",
        service: "api-gateway",
        manifests: [%{"kind" => "Deployment"}],
        strategy: :direct
      }

      assert {:error, reason} = Target.run_task(task, state, [])
      assert reason != nil
    end
  end
end

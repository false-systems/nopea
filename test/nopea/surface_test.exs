defmodule Nopea.SurfaceTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Surface

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)

    Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ ->
      {:error, :not_found}
    end)

    start_supervised!({Nopea.Memory, []})
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "context/2" do
    test "returns context from Memory" do
      ctx = Surface.context("test-svc", "default")
      assert is_map(ctx)
      assert Map.has_key?(ctx, :known)
    end
  end

  describe "explain/2" do
    test "returns explanation string for unknown service" do
      result = Surface.explain("unknown-svc", "default")
      assert result =~ "No deployment history"
      assert result =~ "direct strategy"
    end
  end

  describe "health/0" do
    test "returns health with memory stats" do
      result = Surface.health()
      assert is_list(result.agents)
      assert result.agent_count == 0
      assert is_integer(result.memory.nodes)
      assert is_integer(result.memory.relationships)
    end
  end

  describe "services/0" do
    test "returns empty list when no services deployed" do
      assert Surface.services() == []
    end

    test "returns services after cache population" do
      Nopea.Cache.put_service_state("svc-a", %{status: :completed})
      Nopea.Cache.put_service_state("svc-b", %{status: :completed})

      services = Surface.services()
      assert "svc-a" in services
      assert "svc-b" in services
    end
  end

  describe "status/1" do
    test "returns error when service not found" do
      assert {:error, _} = Surface.status("nonexistent")
    end

    test "returns status from cache" do
      Nopea.Cache.put_service_state("cached-svc", %{status: :completed, last_deploy: "abc"})
      assert {:ok, state} = Surface.status("cached-svc")
      assert state.status == :completed
    end
  end

  describe "history/1" do
    test "returns error for unknown service" do
      assert {:error, :not_found} = Surface.history("unknown")
    end

    test "returns history from cache" do
      Nopea.Cache.put_service_state("hist-svc", %{status: :completed})
      assert {:ok, %{service: "hist-svc", state: _}} = Surface.history("hist-svc")
    end
  end
end

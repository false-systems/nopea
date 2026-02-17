defmodule Nopea.MemoryTest do
  use ExUnit.Case

  alias Nopea.Memory

  setup do
    # ULID is started by the application; just ensure Memory is fresh
    pid = start_supervised!({Memory, []})
    %{pid: pid}
  end

  describe "start_link/1" do
    test "starts with empty graph", %{pid: pid} do
      assert Process.alive?(pid)
      assert Memory.node_count() == 0
      assert Memory.relationship_count() == 0
    end
  end

  describe "record_deploy/1 and get_deploy_context/2" do
    test "records a successful deploy and retrieves context" do
      Memory.record_deploy(%{
        service: "auth-service",
        namespace: "production",
        status: :completed,
        error: nil
      })

      # Cast is async, give it a moment
      Process.sleep(50)

      ctx = Memory.get_deploy_context("auth-service", "production")
      assert ctx.service == "auth-service"
      assert ctx.namespace == "production"
      assert ctx.known == true
    end

    test "records a failed deploy with error pattern" do
      Memory.record_deploy(%{
        service: "api-gateway",
        namespace: "staging",
        status: :failed,
        error: {:timeout, "connection refused"}
      })

      Process.sleep(50)

      ctx = Memory.get_deploy_context("api-gateway", "staging")
      assert ctx.known == true
      assert length(ctx.failure_patterns) == 1
      assert hd(ctx.failure_patterns).error == "timeout"
    end

    test "unknown service returns empty context" do
      ctx = Memory.get_deploy_context("nonexistent", "default")
      assert ctx.known == false
      assert ctx.failure_patterns == []
      assert ctx.dependencies == []
    end
  end

  describe "node_count/0 and relationship_count/0" do
    test "counts increase after recording deploys" do
      assert Memory.node_count() == 0
      assert Memory.relationship_count() == 0

      Memory.record_deploy(%{
        service: "web-app",
        namespace: "default",
        status: :completed,
        error: nil
      })

      Process.sleep(50)

      # service + namespace
      assert Memory.node_count() == 2
      # depends_on
      assert Memory.relationship_count() == 1
    end
  end

  describe "get_graph/0" do
    test "returns the current graph state" do
      graph = Memory.get_graph()
      assert %Kerto.Graph.Graph{} = graph
      assert map_size(graph.nodes) == 0
    end
  end

  describe "decay" do
    test "decay message is handled without crash" do
      # Manually send :decay to trigger the handler
      send(Process.whereis(Memory), :decay)
      Process.sleep(50)

      # Should still be alive and functional
      assert Memory.node_count() == 0
    end
  end
end

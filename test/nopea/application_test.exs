defmodule Nopea.ApplicationTest do
  use ExUnit.Case, async: false

  describe "supervision tree ordering" do
    test "Cache is available before Memory starts and can restore snapshot" do
      # Start Cache first (as the fixed supervision tree does)
      cache_pid = start_supervised!(Nopea.Cache)
      assert Process.alive?(cache_pid)
      assert Nopea.Cache.available?()

      # Now start Memory — it calls restore_snapshot which needs Cache
      memory_pid = start_supervised!({Nopea.Memory, []})
      assert Process.alive?(memory_pid)

      # Memory should be functional
      assert Nopea.Memory.node_count() == 0
    end

    test "Memory can restore snapshot from Cache when started after Cache" do
      start_supervised!(Nopea.Cache)

      # Store a graph snapshot in cache
      graph = Nopea.Graph.Graph.new()

      {graph, _node} =
        Nopea.Graph.Graph.upsert_node(graph, :concept, "test-svc", 0.9, "test-ulid")

      binary = :erlang.term_to_binary(graph)
      Nopea.Cache.put_graph_snapshot(binary)

      # Memory should restore this snapshot on init
      start_supervised!({Nopea.Memory, []})
      assert Nopea.Memory.node_count() == 1
    end
  end
end

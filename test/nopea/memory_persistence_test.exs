defmodule Nopea.MemoryPersistenceTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Memory
  alias Nopea.Test.Factory

  @moduletag :tmp_dir

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)

    Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ ->
      {:error, :not_found}
    end)

    :ok
  end

  describe "disk persistence" do
    test "persists graph to .nopea/graph.etf after record_deploy", %{tmp_dir: tmp_dir} do
      pid = start_supervised!({Memory, workdir: tmp_dir})
      assert is_pid(pid)

      Memory.record_deploy(Factory.build_result(service: "persist-svc"))
      _ = Memory.node_count()

      graph_path = Path.join([tmp_dir, ".nopea", "graph.etf"])
      assert File.exists?(graph_path)

      # Verify file format: version byte + ETF binary
      {:ok, <<1, rest::binary>>} = File.read(graph_path)
      graph = :erlang.binary_to_term(rest, [:safe])
      assert is_struct(graph)
    end

    test "restores graph from disk on restart", %{tmp_dir: tmp_dir} do
      # Start Memory, record a deploy, stop it
      pid1 = start_supervised!({Memory, workdir: tmp_dir}, id: :mem1)
      assert is_pid(pid1)

      Memory.record_deploy(Factory.build_result(service: "restore-svc", namespace: "prod"))
      _ = Memory.node_count()

      # Get context before stop
      ctx_before = Memory.get_deploy_context("restore-svc", "prod")
      assert ctx_before.known == true

      stop_supervised!(:mem1)

      # Restart without ETS (no Cache) — should restore from disk
      pid2 = start_supervised!({Memory, workdir: tmp_dir}, id: :mem2)
      assert is_pid(pid2)

      ctx_after = Memory.get_deploy_context("restore-svc", "prod")
      assert ctx_after.known == true
    end

    test "starts with fresh graph when no disk file exists", %{tmp_dir: tmp_dir} do
      pid = start_supervised!({Memory, workdir: tmp_dir})
      assert is_pid(pid)

      assert Memory.node_count() == 0
      assert Memory.relationship_count() == 0
    end

    test "handles corrupted disk file gracefully", %{tmp_dir: tmp_dir} do
      graph_path = Path.join([tmp_dir, ".nopea", "graph.etf"])
      File.mkdir_p!(Path.dirname(graph_path))
      File.write!(graph_path, "corrupted data")

      pid = start_supervised!({Memory, workdir: tmp_dir})
      assert is_pid(pid)

      # Should start with fresh graph
      assert Memory.node_count() == 0
    end

    test "persists after terminate callback", %{tmp_dir: tmp_dir} do
      pid = start_supervised!({Memory, workdir: tmp_dir}, id: :mem_term)
      assert is_pid(pid)

      Memory.record_deploy(Factory.build_result(service: "term-svc"))
      _ = Memory.node_count()

      # Stop gracefully — terminate/2 should persist
      stop_supervised!(:mem_term)

      graph_path = Path.join([tmp_dir, ".nopea", "graph.etf"])
      assert File.exists?(graph_path)
    end
  end
end

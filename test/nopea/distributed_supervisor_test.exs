defmodule Nopea.DistributedSupervisorTest do
  @moduledoc """
  Tests for the distributed process supervisor.

  Uses Horde.DynamicSupervisor under the hood for cluster-wide process management.
  Workers started via this supervisor are automatically distributed across nodes
  and restarted on surviving nodes if their host node dies.
  """

  use ExUnit.Case, async: false

  alias Nopea.{DistributedRegistry, DistributedSupervisor}

  @moduletag :distributed

  # Start registry once for all tests (required for via tuples)
  setup_all do
    case DistributedRegistry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  # Each test gets a fresh supervisor to avoid interference
  setup do
    name = :"test_supervisor_#{:rand.uniform(1_000_000)}"

    {:ok, sup_pid} = DistributedSupervisor.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(sup_pid) do
        try do
          Supervisor.stop(sup_pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{supervisor: name, supervisor_pid: sup_pid}
  end

  describe "start_link/1" do
    test "starts the supervisor successfully", %{supervisor_pid: sup_pid} do
      assert Process.alive?(sup_pid)
    end
  end

  describe "start_child/1 on default supervisor" do
    # This test uses the global supervisor to verify it works
    test "starts a child process on default supervisor" do
      # Start the default supervisor if not running
      case DistributedSupervisor.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      key = "default-child-#{:rand.uniform(100_000)}"

      child_spec = %{
        id: key,
        start: {Agent, :start_link, [fn -> :running end, [name: DistributedRegistry.via(key)]]}
      }

      assert {:ok, pid} = DistributedSupervisor.start_child(child_spec)
      assert Process.alive?(pid)

      # Clean up
      Agent.stop(pid)
    end
  end

  describe "start_child/2 with named supervisor" do
    test "starts a child process", %{supervisor: sup} do
      key = "child-test-#{:rand.uniform(100_000)}"

      child_spec = %{
        id: key,
        start: {Agent, :start_link, [fn -> :running end, [name: DistributedRegistry.via(key)]]}
      }

      assert {:ok, pid} = Horde.DynamicSupervisor.start_child(sup, child_spec)
      assert Process.alive?(pid)

      # Should be findable via registry
      assert {:ok, ^pid} = DistributedRegistry.lookup(key)

      # Clean up
      Agent.stop(pid)
    end

    test "returns error when starting duplicate child", %{supervisor: sup} do
      key = "dup-child-#{:rand.uniform(100_000)}"

      child_spec = %{
        id: key,
        start: {Agent, :start_link, [fn -> :first end, [name: DistributedRegistry.via(key)]]}
      }

      {:ok, pid1} = Horde.DynamicSupervisor.start_child(sup, child_spec)

      # Try to start another with same key - registry will reject
      dup_spec = %{
        id: "#{key}-dup",
        start: {Agent, :start_link, [fn -> :second end, [name: DistributedRegistry.via(key)]]}
      }

      assert {:error, {:already_started, ^pid1}} =
               Horde.DynamicSupervisor.start_child(sup, dup_spec)

      # Clean up
      Agent.stop(pid1)
    end
  end

  describe "terminate_child/1" do
    test "terminates a running child by pid", %{supervisor: sup} do
      key = "term-child-#{:rand.uniform(100_000)}"

      child_spec = %{
        id: key,
        start: {Agent, :start_link, [fn -> :running end, [name: DistributedRegistry.via(key)]]}
      }

      {:ok, pid} = Horde.DynamicSupervisor.start_child(sup, child_spec)
      assert Process.alive?(pid)

      # Terminate by PID
      assert :ok = Horde.DynamicSupervisor.terminate_child(sup, pid)

      # Process should be dead
      refute Process.alive?(pid)

      # Registry should clean up
      Process.sleep(100)
      assert {:error, :not_found} = DistributedRegistry.lookup(key)
    end
  end

  describe "which_children/0" do
    test "returns list of supervised children", %{supervisor: sup} do
      key1 = "which-1-#{:rand.uniform(100_000)}"
      key2 = "which-2-#{:rand.uniform(100_000)}"

      spec1 = %{
        id: key1,
        start: {Agent, :start_link, [fn -> :one end, [name: DistributedRegistry.via(key1)]]}
      }

      spec2 = %{
        id: key2,
        start: {Agent, :start_link, [fn -> :two end, [name: DistributedRegistry.via(key2)]]}
      }

      {:ok, pid1} = Horde.DynamicSupervisor.start_child(sup, spec1)
      {:ok, pid2} = Horde.DynamicSupervisor.start_child(sup, spec2)

      children = Horde.DynamicSupervisor.which_children(sup)

      # Should contain our children
      pids = Enum.map(children, fn {_id, pid, _type, _modules} -> pid end)
      assert pid1 in pids
      assert pid2 in pids

      # Clean up
      Agent.stop(pid1)
      Agent.stop(pid2)
    end
  end

  describe "count_children/0" do
    test "returns count of supervised children", %{supervisor: sup} do
      initial_count = Horde.DynamicSupervisor.count_children(sup)
      initial_workers = Map.get(initial_count, :workers, 0)

      key = "count-test-#{:rand.uniform(100_000)}"

      spec = %{
        id: key,
        start: {Agent, :start_link, [fn -> :counted end, [name: DistributedRegistry.via(key)]]}
      }

      {:ok, pid} = Horde.DynamicSupervisor.start_child(sup, spec)

      new_count = Horde.DynamicSupervisor.count_children(sup)
      new_workers = Map.get(new_count, :workers, 0)

      assert new_workers == initial_workers + 1

      # Clean up
      Agent.stop(pid)
    end
  end
end

defmodule Nopea.DistributedRegistryTest do
  @moduledoc """
  Tests for the distributed process registry.

  Uses Horde.Registry under the hood for cluster-wide unique process registration.
  In a cluster, only one process per key exists across all nodes.
  """

  use ExUnit.Case, async: false

  alias Nopea.DistributedRegistry

  @moduletag :distributed

  # Poll-based assertion for async operations (replaces Process.sleep barriers)
  defp assert_eventually(fun, timeout_ms \\ 500, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_poll(fun, deadline, interval_ms)
  end

  defp do_poll(fun, deadline, interval_ms) do
    case fun.() do
      true ->
        true

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("assert_eventually timed out")
        else
          Process.sleep(interval_ms)
          do_poll(fun, deadline, interval_ms)
        end
    end
  end

  # Start registry once for all tests
  setup_all do
    case DistributedRegistry.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "via/1" do
    test "returns a via tuple for GenServer registration" do
      key = "via-test-#{:rand.uniform(10000)}"

      via = DistributedRegistry.via(key)
      assert {:via, Horde.Registry, {DistributedRegistry, ^key}} = via
    end

    test "GenServer can be started with via tuple" do
      key = "genserver-via-#{:rand.uniform(10000)}"

      # Start an Agent using the via tuple
      {:ok, agent} = Agent.start_link(fn -> 42 end, name: DistributedRegistry.via(key))

      # Should be findable via lookup
      assert {:ok, ^agent} = DistributedRegistry.lookup(key)

      # Also via GenServer.whereis
      assert ^agent = GenServer.whereis(DistributedRegistry.via(key))

      Agent.stop(agent)
    end

    test "duplicate registration fails with via tuple" do
      key = "dup-via-#{:rand.uniform(10000)}"

      {:ok, agent1} = Agent.start_link(fn -> 1 end, name: DistributedRegistry.via(key))

      # Second registration should fail
      result = Agent.start_link(fn -> 2 end, name: DistributedRegistry.via(key))
      assert {:error, {:already_started, ^agent1}} = result

      Agent.stop(agent1)
    end

    test "registration cleans up when process dies" do
      key = "cleanup-via-#{:rand.uniform(10000)}"

      {:ok, agent} = Agent.start_link(fn -> 42 end, name: DistributedRegistry.via(key))
      assert {:ok, ^agent} = DistributedRegistry.lookup(key)

      # Kill the agent
      Agent.stop(agent)

      # Poll until Horde cleans up the registration
      assert_eventually(fn ->
        DistributedRegistry.lookup(key) == {:error, :not_found}
      end)

      # Should be able to re-register
      {:ok, agent2} = Agent.start_link(fn -> 99 end, name: DistributedRegistry.via(key))
      assert {:ok, ^agent2} = DistributedRegistry.lookup(key)

      Agent.stop(agent2)
    end
  end

  describe "register/1 (self-registration)" do
    test "registers calling process under a key" do
      key = "self-register-#{:rand.uniform(10000)}"

      # Spawn a task that registers itself
      task =
        Task.async(fn ->
          result = DistributedRegistry.register(key)
          send(self(), {:registered, result})
          # Stay alive for lookup
          Process.sleep(1000)
        end)

      # Poll until registration completes
      assert_eventually(fn ->
        match?({:ok, _}, DistributedRegistry.lookup(key))
      end)

      # Should be able to look up the task's pid
      assert {:ok, pid} = DistributedRegistry.lookup(key)
      assert pid == task.pid

      Task.shutdown(task, :brutal_kill)
    end

    test "self-registration returns error when already registered" do
      key = "self-dup-#{:rand.uniform(10000)}"

      # First process registers
      task1 =
        Task.async(fn ->
          DistributedRegistry.register(key)
          Process.sleep(1000)
        end)

      # Poll until first registration completes
      assert_eventually(fn ->
        match?({:ok, _}, DistributedRegistry.lookup(key))
      end)

      # Second process tries to register same key
      task2 =
        Task.async(fn ->
          DistributedRegistry.register(key)
        end)

      result = Task.await(task2)
      assert {:error, {:already_registered, _pid}} = result

      Task.shutdown(task1, :brutal_kill)
    end
  end

  describe "lookup/1" do
    test "returns error for unknown key" do
      assert {:error, :not_found} =
               DistributedRegistry.lookup("nonexistent-key-#{:rand.uniform(10000)}")
    end

    test "finds registered process" do
      key = "lookup-test-#{:rand.uniform(10000)}"
      {:ok, agent} = Agent.start_link(fn -> :found end, name: DistributedRegistry.via(key))

      # Horde registration may need a moment to propagate
      assert_eventually(fn ->
        match?({:ok, _}, DistributedRegistry.lookup(key))
      end)

      assert {:ok, ^agent} = DistributedRegistry.lookup(key)

      Agent.stop(agent)
    end
  end

  describe "unregister/1" do
    test "returns ok for unknown key (idempotent)" do
      assert :ok = DistributedRegistry.unregister("never-registered-#{:rand.uniform(10000)}")
    end
  end

  describe "list_all/0" do
    test "returns registered keys" do
      # Use unique keys to avoid conflicts with other tests
      key1 = "list-test-1-#{:rand.uniform(100_000)}"
      key2 = "list-test-2-#{:rand.uniform(100_000)}"

      {:ok, agent1} = Agent.start_link(fn -> :one end, name: DistributedRegistry.via(key1))
      {:ok, agent2} = Agent.start_link(fn -> :two end, name: DistributedRegistry.via(key2))

      all = DistributedRegistry.list_all()

      assert Enum.any?(all, fn {k, _pid} -> k == key1 end)
      assert Enum.any?(all, fn {k, _pid} -> k == key2 end)

      Agent.stop(agent1)
      Agent.stop(agent2)
    end
  end
end

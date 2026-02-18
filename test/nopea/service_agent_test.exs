defmodule Nopea.ServiceAgentTest do
  use ExUnit.Case

  import Mox

  alias Nopea.ServiceAgent
  alias Nopea.Deploy.Spec

  setup :verify_on_exit!

  setup do
    Mox.set_mox_global()
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
    start_supervised!(Nopea.ServiceAgent.Supervisor)
    start_supervised!(Nopea.Cache)
    start_supervised!({Nopea.Memory, []})
    :ok
  end

  defp make_spec(service, opts \\ []) do
    %Spec{
      service: service,
      namespace: Keyword.get(opts, :namespace, "default"),
      manifests: Keyword.get(opts, :manifests, []),
      strategy: Keyword.get(opts, :strategy, :direct)
    }
  end

  describe "ensure_started/1" do
    test "starts and registers an agent" do
      pid = ServiceAgent.ensure_started("my-svc")
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns existing agent on second call" do
      pid1 = ServiceAgent.ensure_started("my-svc")
      pid2 = ServiceAgent.ensure_started("my-svc")
      assert pid1 == pid2
    end

    test "different services get different agents" do
      pid1 = ServiceAgent.ensure_started("svc-a")
      pid2 = ServiceAgent.ensure_started("svc-b")
      assert pid1 != pid2
    end
  end

  describe "deploy/2" do
    test "returns deploy result" do
      spec = make_spec("deploy-svc")
      result = ServiceAgent.deploy("deploy-svc", spec)
      assert result.status == :completed
      assert result.service == "deploy-svc"
    end

    test "serializes concurrent deploys to same service" do
      spec = make_spec("serial-svc")

      tasks =
        for _i <- 1..3 do
          Task.async(fn -> ServiceAgent.deploy("serial-svc", spec) end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1.status == :completed))
      assert length(results) == 3

      # All went through same agent — deploy_count should be 3
      {:ok, status} = ServiceAgent.status("serial-svc")
      assert status.deploy_count == 3
    end

    test "concurrent deploys to different services run in parallel" do
      specs =
        for i <- 1..5 do
          svc = "parallel-svc-#{i}"
          {svc, make_spec(svc)}
        end

      tasks =
        for {svc, spec} <- specs do
          Task.async(fn -> ServiceAgent.deploy(svc, spec) end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1.status == :completed))
      assert length(results) == 5
    end
  end

  describe "status/1" do
    test "returns status after deploy" do
      spec = make_spec("status-svc")
      ServiceAgent.deploy("status-svc", spec)

      {:ok, status} = ServiceAgent.status("status-svc")
      assert status.service == "status-svc"
      assert status.status == :idle
      assert status.deploy_count == 1
      assert status.queue_length == 0
      assert status.last_result != nil
    end

    test "returns error for unknown service" do
      assert {:error, :not_found} = ServiceAgent.status("nonexistent")
    end
  end

  describe "health/0" do
    test "lists all active agents" do
      ServiceAgent.ensure_started("health-a")
      ServiceAgent.ensure_started("health-b")

      agents = ServiceAgent.health()
      services = Enum.map(agents, & &1.service)
      assert "health-a" in services
      assert "health-b" in services
    end
  end

  describe "crash recovery" do
    test "agent recovers after crash" do
      pid = ServiceAgent.ensure_started("crash-svc")
      Process.exit(pid, :kill)

      # Give supervisor time to restart
      Process.sleep(50)

      {:ok, status} = ServiceAgent.status("crash-svc")
      assert status.service == "crash-svc"
      assert status.status == :idle
      # State resets on crash — deploy_count back to 0
      assert status.deploy_count == 0
    end

    test "recovers last_result from cache after restart" do
      spec = make_spec("cache-svc")
      result = ServiceAgent.deploy("cache-svc", spec)
      assert result.status == :completed

      # Kill and let supervisor restart
      [{pid, _}] = Registry.lookup(Nopea.Registry, {:service, "cache-svc"})
      Process.exit(pid, :kill)
      Process.sleep(50)

      {:ok, status} = ServiceAgent.status("cache-svc")
      assert status.last_result != nil
      assert status.last_result.status == :completed
    end
  end

  describe "cooldown after crash" do
    test "delays next queued deploy after worker crash" do
      # Make apply_manifests crash to trigger the DOWN handler
      Mox.expect(Nopea.K8sMock, :apply_manifests, 2, fn _manifests, _ns ->
        raise "boom"
      end)

      spec = make_spec("cooldown-svc", manifests: [%{"kind" => "Deployment"}])

      # Fire two deploys concurrently — first will crash, second gets queued
      task1 = Task.async(fn -> ServiceAgent.deploy("cooldown-svc", spec) end)
      Process.sleep(10)
      task2 = Task.async(fn -> ServiceAgent.deploy("cooldown-svc", spec) end)

      # First deploy fails from crash
      result1 = Task.await(task1, 10_000)
      assert result1.status == :failed
      assert match?({:worker_crash, _}, result1.error)

      # Second deploy should eventually complete (after cooldown + crash)
      result2 = Task.await(task2, 10_000)
      assert result2.status == :failed

      # Both processed
      {:ok, status} = ServiceAgent.status("cooldown-svc")
      assert status.deploy_count == 2
    end
  end

  describe "queue limit" do
    test "rejects deploys when queue is full" do
      test_pid = self()

      # First call blocks; worker sends its pid so we can unblock it
      Mox.expect(Nopea.K8sMock, :apply_manifests, fn _manifests, _ns ->
        send(test_pid, {:deploy_started, self()})

        receive do
          :continue -> {:ok, []}
        end
      end)

      spec = make_spec("queue-svc", manifests: [%{"kind" => "Deployment"}])

      # Start first deploy (will block in apply_manifests)
      task1 = Task.async(fn -> ServiceAgent.deploy("queue-svc", spec) end)
      assert_receive {:deploy_started, worker_pid}, 5_000

      # Queue 10 more (the max)
      queued_tasks =
        for _i <- 1..10 do
          Task.async(fn -> ServiceAgent.deploy("queue-svc", spec) end)
        end

      # Give queued tasks time to reach the agent
      Process.sleep(50)

      # 11th should be rejected immediately with :queue_full
      overflow_result = ServiceAgent.deploy("queue-svc", spec)
      assert overflow_result.status == :failed
      assert overflow_result.error == :queue_full

      # Stub remaining apply_manifests calls for the queued deploys
      Mox.stub(Nopea.K8sMock, :apply_manifests, fn _manifests, _ns ->
        {:ok, []}
      end)

      # Unblock the first deploy worker — let everything drain
      send(worker_pid, :continue)
      _results = Task.await_many([task1 | queued_tasks], 30_000)
    end
  end

  describe "idle timeout" do
    test "agent stops after idle timeout" do
      # Override the idle timeout by sending the message directly
      pid = ServiceAgent.ensure_started("idle-svc")
      assert Process.alive?(pid)

      # Simulate the idle timeout firing
      send(pid, :idle_timeout)
      Process.sleep(50)

      # Agent should have stopped
      refute Process.alive?(pid)
    end

    test "idle timeout is rescheduled during deploy" do
      pid = ServiceAgent.ensure_started("busy-svc")

      # Deploy keeps the agent alive
      spec = make_spec("busy-svc")
      ServiceAgent.deploy("busy-svc", spec)

      # Agent still alive after deploy
      assert Process.alive?(pid)
      {:ok, status} = ServiceAgent.status("busy-svc")
      assert status.deploy_count == 1
    end
  end
end

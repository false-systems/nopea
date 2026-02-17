defmodule Nopea.Integration.ServiceAgentDeployTest do
  @moduledoc """
  Integration tests proving per-service agent architecture at scale.

  50 services deploying concurrently, crash isolation, fallback behavior,
  and health reporting.
  """

  use ExUnit.Case

  alias Nopea.ServiceAgent
  alias Nopea.Deploy
  alias Nopea.Deploy.Spec

  @moduletag :integration

  setup do
    Mox.set_mox_global(self())
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
    start_supervised!(Nopea.ServiceAgent.Supervisor)
    start_supervised!(Nopea.Cache)
    start_supervised!({Nopea.Memory, []})
    :ok
  end

  defp make_spec(service) do
    %Spec{
      service: service,
      namespace: "default",
      manifests: [],
      strategy: :direct
    }
  end

  describe "50-service concurrent deploy" do
    test "all services deploy without interference" do
      tasks =
        for i <- 1..50 do
          svc = "svc-#{i}"

          Task.async(fn ->
            result = ServiceAgent.deploy(svc, make_spec(svc))
            {svc, result}
          end)
        end

      results = Task.await_many(tasks, 30_000)

      assert length(results) == 50

      Enum.each(results, fn {svc, result} ->
        assert result.status == :completed, "#{svc} failed: #{inspect(result.error)}"
        assert result.service == svc
      end)
    end

    test "each service gets its own agent" do
      for i <- 1..50 do
        ServiceAgent.deploy("agent-svc-#{i}", make_spec("agent-svc-#{i}"))
      end

      agents = ServiceAgent.health()
      agent_services = MapSet.new(agents, & &1.service)

      for i <- 1..50 do
        assert MapSet.member?(agent_services, "agent-svc-#{i}")
      end
    end
  end

  describe "crash isolation" do
    test "one agent crash does not affect other services" do
      # Start 3 services
      for svc <- ["stable-1", "stable-2", "crash-target"] do
        ServiceAgent.deploy(svc, make_spec(svc))
      end

      # Kill the crash-target agent
      {:ok, status} = ServiceAgent.status("crash-target")
      assert status.deploy_count == 1

      pid = ServiceAgent.ensure_started("crash-target")
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Other services still healthy
      {:ok, s1} = ServiceAgent.status("stable-1")
      assert s1.status == :idle
      assert s1.deploy_count == 1

      {:ok, s2} = ServiceAgent.status("stable-2")
      assert s2.status == :idle
      assert s2.deploy_count == 1

      # Crash-target recovered but lost state
      {:ok, crashed} = ServiceAgent.status("crash-target")
      assert crashed.status == :idle
      assert crashed.deploy_count == 0
    end
  end

  describe "Deploy.deploy/1 fallback" do
    test "falls back to Deploy.run/1 when Supervisor not running" do
      # Stop the ServiceAgent.Supervisor
      stop_supervised!(Nopea.ServiceAgent.Supervisor)

      spec = make_spec("fallback-svc")
      result = Deploy.deploy(spec)

      assert result.status == :completed
      assert result.service == "fallback-svc"

      # No agent was created (supervisor not running)
      assert {:error, :not_found} = ServiceAgent.status("fallback-svc")
    end
  end

  describe "MCP deploy routes through ServiceAgent" do
    test "agent exists after MCP deploy" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_deploy",
          "arguments" => %{"service" => "mcp-routed-svc", "strategy" => "direct"}
        }
      }

      assert {:ok, response} = Nopea.MCP.handle_request(request)
      content = hd(response["result"]["content"])["text"]
      decoded = Jason.decode!(content)
      assert decoded["status"] == "completed"

      # ServiceAgent was created as a side effect
      {:ok, status} = ServiceAgent.status("mcp-routed-svc")
      assert status.deploy_count == 1
    end
  end

  describe "memory integration" do
    test "memory records deploys from all services" do
      services = for i <- 1..10, do: "mem-svc-#{i}"

      tasks =
        for svc <- services do
          Task.async(fn -> ServiceAgent.deploy(svc, make_spec(svc)) end)
        end

      Task.await_many(tasks, 10_000)

      # Memory.record_deploy is a cast — give it time
      Process.sleep(100)

      Enum.each(services, fn svc ->
        ctx = Nopea.Memory.get_deploy_context(svc, "default")
        assert ctx.known == true, "#{svc} not recorded in memory"
      end)
    end
  end

  describe "health tool" do
    test "reports all active agents correctly" do
      for i <- 1..5 do
        ServiceAgent.deploy("health-svc-#{i}", make_spec("health-svc-#{i}"))
      end

      agents = ServiceAgent.health()
      health_agents = Enum.filter(agents, &String.starts_with?(&1.service, "health-svc-"))
      assert length(health_agents) == 5

      Enum.each(health_agents, fn agent ->
        assert agent.status == :idle
        assert agent.deploy_count == 1
      end)
    end
  end
end

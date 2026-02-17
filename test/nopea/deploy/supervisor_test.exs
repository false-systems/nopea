defmodule Nopea.Deploy.SupervisorTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Deploy.Supervisor, as: DeploySupervisor

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    start_supervised!({Nopea.Memory, []})
    start_supervised!(Nopea.Cache)
    start_supervised!(DeploySupervisor)
    :ok
  end

  describe "start_deploy/1" do
    test "starts a deploy worker" do
      spec = %{service: "sup-test-svc", namespace: "default", manifests: [], strategy: :direct}

      assert {:ok, pid} = DeploySupervisor.start_deploy(spec)
      assert Process.alive?(pid)

      # Worker will complete and terminate
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end

    test "can start multiple concurrent deploys" do
      specs =
        for i <- 1..3 do
          %{service: "svc-#{i}", namespace: "default", manifests: [], strategy: :direct}
        end

      pids =
        Enum.map(specs, fn spec ->
          {:ok, pid} = DeploySupervisor.start_deploy(spec)
          pid
        end)

      assert length(pids) == 3
      # All different PIDs
      assert length(Enum.uniq(pids)) == 3
    end
  end
end

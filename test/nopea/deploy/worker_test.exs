defmodule Nopea.Deploy.WorkerTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Deploy.Worker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    start_supervised!({Nopea.Memory, []})
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "start_link/1 and execution" do
    test "worker runs deploy and stops normally" do
      spec = %{service: "worker-test-svc", namespace: "default", manifests: [], strategy: :direct}

      {:ok, pid} = Worker.start_link(spec)
      ref = Process.monitor(pid)

      # Worker sends :execute to itself and stops after deploy
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end
  end
end

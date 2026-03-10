defmodule Nopea.Progressive.MonitorTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Progressive.Monitor
  alias Nopea.Test.Factory

  setup :set_mox_global
  setup :verify_on_exit!

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)

    Mox.stub(Nopea.K8sMock, :get_resource, fn _, _, _, _ ->
      {:error, :not_found}
    end)

    Mox.stub(Nopea.K8sMock, :patch_resource, fn _, _, _, _, _ ->
      {:ok, %{}}
    end)

    Mox.stub(Nopea.K8sMock, :delete_resource, fn _, _, _, _ ->
      :ok
    end)

    start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
    start_supervised!({Nopea.Memory, workdir: tmp_dir})
    start_supervised!(Nopea.Cache)
    :ok
  end

  defp build_spec(service \\ "canary-svc") do
    Factory.build_spec(
      service: service,
      namespace: "default",
      strategy: :canary,
      manifests: [Factory.sample_deployment_manifest(service)]
    )
  end

  describe "start_link/1 and status/1" do
    test "starts monitor and returns progressing status" do
      spec = build_spec()
      deploy_id = "test-deploy-001"

      {:ok, _pid} =
        start_supervised!({Monitor, {deploy_id, spec, :canary}}, id: :mon1)
        |> then(&{:ok, &1})

      assert {:ok, rollout} = Monitor.status(deploy_id)
      assert rollout.deploy_id == deploy_id
      assert rollout.service == "canary-svc"
      assert rollout.phase == :progressing
      assert rollout.strategy == :canary
    end
  end

  describe "promote/1" do
    test "patches rollout and updates phase to promoted" do
      Mox.expect(Nopea.K8sMock, :patch_resource, fn
        "kulta.io/v1alpha1", "Rollout", "canary-svc", "default", patch ->
          assert patch["metadata"]["annotations"]["kulta.io/promote"] == "true"
          {:ok, %{"status" => %{"phase" => "Healthy"}}}
      end)

      spec = build_spec()
      deploy_id = "test-promote-001"
      start_supervised!({Monitor, {deploy_id, spec, :canary}}, id: :mon_promote)

      assert {:ok, rollout} = Monitor.promote(deploy_id)
      assert rollout.phase == :promoted
    end

    test "returns error when patch fails" do
      Mox.expect(Nopea.K8sMock, :patch_resource, fn _, _, _, _, _ ->
        {:error, :forbidden}
      end)

      spec = build_spec()
      deploy_id = "test-promote-err"
      start_supervised!({Monitor, {deploy_id, spec, :canary}}, id: :mon_promote_err)

      assert {:error, :forbidden} = Monitor.promote(deploy_id)
    end
  end

  describe "rollback/1" do
    test "deletes rollout and updates phase to failed" do
      Mox.expect(Nopea.K8sMock, :delete_resource, fn
        "kulta.io/v1alpha1", "Rollout", "canary-svc", "default" ->
          :ok
      end)

      spec = build_spec()
      deploy_id = "test-rollback-001"
      start_supervised!({Monitor, {deploy_id, spec, :canary}}, id: :mon_rollback)

      assert {:ok, rollout} = Monitor.rollback(deploy_id)
      assert rollout.phase == :failed
    end
  end

  describe "status/1 for nonexistent monitor" do
    test "returns not_found" do
      assert {:error, :not_found} = Monitor.status("nonexistent-deploy")
    end
  end

  describe "list_active/0" do
    test "returns all active rollouts" do
      spec1 = build_spec("svc-a")
      spec2 = build_spec("svc-b")

      start_supervised!({Monitor, {"deploy-a", spec1, :canary}}, id: :mon_a)
      start_supervised!({Monitor, {"deploy-b", spec2, :blue_green}}, id: :mon_b)

      active = Monitor.list_active()
      deploy_ids = Enum.map(active, & &1.deploy_id)
      assert "deploy-a" in deploy_ids
      assert "deploy-b" in deploy_ids
    end
  end

  describe "polling" do
    test "updates rollout phase from polled status" do
      Mox.expect(Nopea.K8sMock, :get_resource, fn
        "kulta.io/v1alpha1", "Rollout", "poll-svc", "default" ->
          {:ok,
           %{"status" => %{"phase" => "Healthy", "currentStepIndex" => 3, "totalSteps" => 4}}}
      end)

      spec = build_spec("poll-svc")
      deploy_id = "test-poll-001"
      start_supervised!({Monitor, {deploy_id, spec, :canary}}, id: :mon_poll)

      # Trigger poll manually
      pid = Monitor.whereis(deploy_id)
      send(pid, :poll)

      # Wait for the monitor to process poll and terminate
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # Monitor should have stopped since "Healthy" is terminal
      assert {:error, :not_found} = Monitor.status(deploy_id)
    end
  end
end

defmodule Nopea.SupervisorTest do
  use ExUnit.Case, async: false

  alias Nopea.Supervisor, as: NopSupervisor

  # Supervisor tests require Git (Workers call Git on startup)
  @moduletag :integration

  setup do
    dev_path = Path.join([File.cwd!(), "nopea-git", "target", "release", "nopea-git"])

    if File.exists?(dev_path) do
      start_supervised!(Nopea.Cache)
      start_supervised!({Registry, keys: :unique, name: Nopea.Registry})
      start_supervised!(Nopea.Git)
      start_supervised!(Nopea.Supervisor)

      # Cleanup any leftover workers on exit
      on_exit(fn ->
        try do
          NopSupervisor.list_workers()
          |> Enum.each(fn {name, _pid} ->
            try do
              NopSupervisor.stop_worker(name)
            rescue
              _ -> :ok
            end
          end)
        rescue
          _ -> :ok
        end
      end)

      {:ok, binary_available: true}
    else
      IO.puts("Skipping: Rust binary not built")
      {:ok, binary_available: false}
    end
  end

  describe "start_worker/1" do
    @tag timeout: 30_000
    test "starts a worker for a repo config", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      config = test_config("start-test")

      assert {:ok, pid} = NopSupervisor.start_worker(config)
      assert Process.alive?(pid)

      NopSupervisor.stop_worker(config.name)
    end

    @tag timeout: 30_000
    test "returns error for duplicate repo name", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      config = test_config("dup-test")

      {:ok, _pid} = NopSupervisor.start_worker(config)
      assert {:error, {:already_started, _}} = NopSupervisor.start_worker(config)

      NopSupervisor.stop_worker(config.name)
    end
  end

  describe "stop_worker/1" do
    @tag timeout: 30_000
    test "stops a running worker", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      config = test_config("stop-test")

      {:ok, pid} = NopSupervisor.start_worker(config)
      assert Process.alive?(pid)

      # Monitor the process to wait for termination
      ref = Process.monitor(pid)

      :ok = NopSupervisor.stop_worker(config.name)

      # Wait for process to actually terminate
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} ->
          refute Process.alive?(pid)
      after
        5_000 ->
          flunk("Process did not terminate within timeout")
      end
    end

    @tag timeout: 30_000
    test "returns error for unknown worker", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      assert {:error, :not_found} = NopSupervisor.stop_worker("unknown-repo")
    end
  end

  describe "list_workers/0" do
    @tag timeout: 30_000
    test "returns list of active workers", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      config1 = test_config("list-1")
      config2 = test_config("list-2")

      {:ok, _} = NopSupervisor.start_worker(config1)
      {:ok, _} = NopSupervisor.start_worker(config2)

      workers = NopSupervisor.list_workers()
      assert Enum.any?(workers, fn {name, _pid} -> name == config1.name end)
      assert Enum.any?(workers, fn {name, _pid} -> name == config2.name end)

      NopSupervisor.stop_worker(config1.name)
      NopSupervisor.stop_worker(config2.name)
    end
  end

  describe "get_worker/1" do
    @tag timeout: 30_000
    test "returns pid for known worker", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      config = test_config("get-test")

      {:ok, pid} = NopSupervisor.start_worker(config)
      assert {:ok, ^pid} = NopSupervisor.get_worker(config.name)

      NopSupervisor.stop_worker(config.name)
    end

    @tag timeout: 30_000
    test "returns error for unknown worker", %{binary_available: available} do
      unless available, do: flunk("Rust binary not built")

      assert {:error, :not_found} = NopSupervisor.get_worker("unknown")
    end
  end

  # Use a real public repo for tests
  defp test_config(prefix) do
    %{
      name: "#{prefix}-#{:rand.uniform(10000)}",
      url: "https://github.com/octocat/Hello-World.git",
      branch: "master",
      path: nil,
      interval: 300_000,
      target_namespace: nil
    }
  end
end

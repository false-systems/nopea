defmodule Nopea.CacheTest do
  use ExUnit.Case, async: false

  alias Nopea.Cache

  setup do
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "deployments" do
    test "stores and retrieves deployment" do
      service = "auth-svc-#{:rand.uniform(1000)}"
      deploy_id = "01ABC"
      data = %{status: :completed, duration_ms: 150}

      :ok = Cache.put_deployment(service, deploy_id, data)
      assert {:ok, ^data} = Cache.get_deployment(service, deploy_id)
    end

    test "returns error for unknown deployment" do
      assert {:error, :not_found} = Cache.get_deployment("unknown", "unknown")
    end

    test "lists all deployments for a service" do
      service = "svc-#{:rand.uniform(1000)}"

      :ok = Cache.put_deployment(service, "deploy-1", %{status: :completed})
      :ok = Cache.put_deployment(service, "deploy-2", %{status: :failed})

      deploys = Cache.list_deployments(service)
      assert length(deploys) == 2
    end
  end

  describe "service state" do
    test "stores and retrieves service state" do
      service = "svc-#{:rand.uniform(1000)}"
      state = %{status: :completed, last_deploy: "01ABC"}

      :ok = Cache.put_service_state(service, state)
      assert {:ok, ^state} = Cache.get_service_state(service)
    end

    test "returns error for unknown service" do
      assert {:error, :not_found} = Cache.get_service_state("unknown")
    end

    test "lists all services" do
      svc1 = "svc-a-#{:rand.uniform(1000)}"
      svc2 = "svc-b-#{:rand.uniform(1000)}"

      :ok = Cache.put_service_state(svc1, %{status: :ok})
      :ok = Cache.put_service_state(svc2, %{status: :ok})

      services = Cache.list_services()
      assert svc1 in services
      assert svc2 in services
    end
  end

  describe "graph snapshot" do
    test "stores and retrieves graph snapshot" do
      binary = :erlang.term_to_binary(%{nodes: %{}, relationships: %{}})

      :ok = Cache.put_graph_snapshot(binary)
      assert {:ok, ^binary} = Cache.get_graph_snapshot()
    end

    test "returns error when no snapshot" do
      assert {:error, :not_found} = Cache.get_graph_snapshot()
    end
  end

  describe "last applied (for drift detection)" do
    test "stores and retrieves last-applied manifest" do
      service = "svc-#{:rand.uniform(1000)}"
      resource_key = "Deployment/default/my-app"
      manifest = %{"apiVersion" => "apps/v1", "kind" => "Deployment"}

      :ok = Cache.put_last_applied(service, resource_key, manifest)
      assert {:ok, ^manifest} = Cache.get_last_applied(service, resource_key)
    end

    test "returns error for unknown resource" do
      assert {:error, :not_found} = Cache.get_last_applied("svc", "unknown")
    end

    test "lists all last-applied manifests for service" do
      service = "svc-#{:rand.uniform(1000)}"

      :ok = Cache.put_last_applied(service, "Deployment/default/app1", %{"kind" => "Deployment"})
      :ok = Cache.put_last_applied(service, "Service/default/app1", %{"kind" => "Service"})

      manifests = Cache.list_last_applied(service)
      assert length(manifests) == 2
    end
  end

  describe "available?/0" do
    test "returns true when tables exist" do
      assert Cache.available?()
    end
  end
end

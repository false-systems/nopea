defmodule Nopea.ClusterTest do
  @moduledoc """
  Tests for the cluster topology module.

  Uses libcluster for automatic node discovery in Kubernetes.
  In tests, we verify the topology configuration is valid.
  """

  use ExUnit.Case, async: true

  alias Nopea.Cluster

  @moduletag :cluster

  describe "child_spec/1" do
    test "returns valid child spec for supervisor" do
      spec = Cluster.child_spec([])

      assert %{
               id: Nopea.Cluster.Supervisor,
               start: {Nopea.Cluster.Supervisor, :start_link, _},
               type: :supervisor
             } = spec
    end
  end

  describe "topology/0" do
    test "returns K8s DNS topology in production-like config" do
      # Simulate production environment
      Application.put_env(:nopea, :cluster_enabled, true)
      Application.put_env(:nopea, :cluster_strategy, :kubernetes_dns)
      Application.put_env(:nopea, :cluster_service, "nopea-headless")
      Application.put_env(:nopea, :cluster_app_name, "nopea")
      Application.put_env(:nopea, :pod_namespace, "nopea-system")

      topology = Cluster.topology()

      assert Keyword.has_key?(topology, :k8s)
      k8s_config = topology[:k8s]

      # libcluster strategy module
      assert k8s_config[:strategy] == Elixir.Cluster.Strategy.Kubernetes.DNS
      assert k8s_config[:config][:service] == "nopea-headless"
      assert k8s_config[:config][:application_name] == "nopea"
      assert k8s_config[:config][:namespace] == "nopea-system"

      # Clean up
      Application.delete_env(:nopea, :cluster_enabled)
      Application.delete_env(:nopea, :cluster_strategy)
      Application.delete_env(:nopea, :cluster_service)
      Application.delete_env(:nopea, :cluster_app_name)
      Application.delete_env(:nopea, :pod_namespace)
    end

    test "returns empty topology when clustering is disabled" do
      Application.put_env(:nopea, :cluster_enabled, false)

      topology = Cluster.topology()

      assert topology == []

      Application.delete_env(:nopea, :cluster_enabled)
    end

    test "returns gossip topology for local development" do
      Application.put_env(:nopea, :cluster_enabled, true)
      Application.put_env(:nopea, :cluster_strategy, :gossip)

      topology = Cluster.topology()

      assert Keyword.has_key?(topology, :gossip)
      gossip_config = topology[:gossip]
      # libcluster strategy module
      assert gossip_config[:strategy] == Elixir.Cluster.Strategy.Gossip

      Application.delete_env(:nopea, :cluster_enabled)
      Application.delete_env(:nopea, :cluster_strategy)
    end
  end

  describe "enabled?/0" do
    test "returns true when cluster_enabled is true" do
      Application.put_env(:nopea, :cluster_enabled, true)
      assert Cluster.enabled?()
      Application.delete_env(:nopea, :cluster_enabled)
    end

    test "returns false when cluster_enabled is false" do
      Application.put_env(:nopea, :cluster_enabled, false)
      refute Cluster.enabled?()
      Application.delete_env(:nopea, :cluster_enabled)
    end

    test "returns false when cluster_enabled is not set" do
      Application.delete_env(:nopea, :cluster_enabled)
      refute Cluster.enabled?()
    end
  end
end

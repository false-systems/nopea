defmodule Nopea.Memory.IngestorTest do
  use ExUnit.Case, async: true

  alias Kerto.Graph.{Graph, Identity}
  alias Nopea.Memory.Ingestor

  describe "ingest/2 with successful deploy" do
    setup do
      graph = Graph.new()

      result = %{
        service: "auth-service",
        namespace: "production",
        status: :completed,
        error: nil
      }

      graph = Ingestor.ingest(graph, result)
      %{graph: graph, result: result}
    end

    test "creates service node", %{graph: graph} do
      id = Identity.compute_id(:concept, "auth-service")
      assert {:ok, node} = Graph.get_node(graph, id)
      assert node.kind == :concept
      assert node.name == "auth-service"
    end

    test "creates namespace node", %{graph: graph} do
      id = Identity.compute_id(:concept, "namespace:production")
      assert {:ok, node} = Graph.get_node(graph, id)
      assert node.kind == :concept
    end

    test "creates service→namespace relationship", %{graph: graph} do
      service_id = Identity.compute_id(:concept, "auth-service")
      ns_id = Identity.compute_id(:concept, "namespace:production")

      rels = Graph.neighbors(graph, service_id, :outgoing)
      assert length(rels) == 1

      [rel] = rels
      assert rel.source == service_id
      assert rel.target == ns_id
      assert rel.relation == :deployed_to
    end

    test "has 2 nodes and 1 relationship", %{graph: graph} do
      assert Graph.node_count(graph) == 2
      assert Graph.relationship_count(graph) == 1
    end
  end

  describe "ingest/2 with failed deploy" do
    setup do
      graph = Graph.new()

      result = %{
        service: "api-gateway",
        namespace: "staging",
        status: :failed,
        error: {:timeout, "connection refused"}
      }

      graph = Ingestor.ingest(graph, result)
      %{graph: graph}
    end

    test "creates error node for failure", %{graph: graph} do
      id = Identity.compute_id(:error, "timeout")
      assert {:ok, node} = Graph.get_node(graph, id)
      assert node.kind == :error
      assert node.name == "timeout"
    end

    test "creates service→breaks→error relationship", %{graph: graph} do
      service_id = Identity.compute_id(:concept, "api-gateway")

      breaks_rels =
        graph
        |> Graph.neighbors(service_id, :outgoing)
        |> Enum.filter(fn rel -> rel.relation == :breaks end)

      assert length(breaks_rels) == 1
      [rel] = breaks_rels
      assert rel.target == Identity.compute_id(:error, "timeout")
      # initial weight from Relationship.new
      assert rel.weight == 0.5
    end

    test "has 3 nodes (service, namespace, error)", %{graph: graph} do
      assert Graph.node_count(graph) == 3
    end
  end

  describe "ingest/2 reinforcement" do
    test "repeated deploys reinforce node relevance" do
      graph = Graph.new()

      result = %{service: "user-service", namespace: "default", status: :completed, error: nil}

      graph = Ingestor.ingest(graph, result)
      graph = Ingestor.ingest(graph, result)
      graph = Ingestor.ingest(graph, result)

      id = Identity.compute_id(:concept, "user-service")
      {:ok, node} = Graph.get_node(graph, id)

      # After 3 observations, relevance should be higher than initial 0.5
      assert node.observations == 3
      assert node.relevance > 0.5
    end

    test "repeated failures increase breaks relationship weight" do
      graph = Graph.new()

      result = %{
        service: "payment-service",
        namespace: "production",
        status: :failed,
        error: "oom_killed"
      }

      graph = Ingestor.ingest(graph, result)
      graph = Ingestor.ingest(graph, result)

      service_id = Identity.compute_id(:concept, "payment-service")

      [rel] =
        graph
        |> Graph.neighbors(service_id, :outgoing)
        |> Enum.filter(fn r -> r.relation == :breaks end)

      assert rel.observations == 2
      # Weight should increase after reinforcement with 0.8 confidence
      assert rel.weight > 0.5
    end
  end

  describe "ingest/2 with concurrent deploys" do
    test "records concurrent deploy services as nodes" do
      graph = Graph.new()

      result = %{
        service: "auth-service",
        namespace: "production",
        status: :failed,
        error: "connection_refused",
        concurrent_deploys: ["redis", "config-service"]
      }

      graph = Ingestor.ingest(graph, result)

      # Should have nodes for concurrent services
      redis_id = Identity.compute_id(:concept, "redis")
      config_id = Identity.compute_id(:concept, "config-service")

      assert {:ok, _} = Graph.get_node(graph, redis_id)
      assert {:ok, _} = Graph.get_node(graph, config_id)
    end
  end

  describe "ingest/2 edge cases" do
    test "handles unknown result format gracefully" do
      graph = Graph.new()
      assert Graph.new() == Ingestor.ingest(graph, %{unknown: "format"})
    end

    test "handles nil error on failed deploy" do
      graph = Graph.new()

      result = %{
        service: "broken-service",
        namespace: "default",
        status: :failed,
        error: nil
      }

      # Should not crash — no error node created when error is nil
      graph = Ingestor.ingest(graph, result)
      # service + namespace only
      assert Graph.node_count(graph) == 2
    end

    test "normalizes different error formats" do
      graph = Graph.new()

      # Tuple error
      r1 = %{service: "svc-a", namespace: "ns", status: :failed, error: {:crash, "bad"}}
      graph = Ingestor.ingest(graph, r1)
      assert {:ok, _} = Graph.get_node(graph, Identity.compute_id(:error, "crash"))

      # String error
      r2 = %{service: "svc-b", namespace: "ns", status: :failed, error: "timeout"}
      graph = Ingestor.ingest(graph, r2)
      assert {:ok, _} = Graph.get_node(graph, Identity.compute_id(:error, "timeout"))
    end
  end
end

defmodule Nopea.Memory.QueryTest do
  use ExUnit.Case, async: true

  alias Nopea.Graph.{Graph, Identity}
  alias Nopea.Memory.{Ingestor, Query}

  defp build_graph_with_history do
    graph = Graph.new()

    # 3 successful deploys for auth-service
    graph =
      Ingestor.ingest(graph, %{
        service: "auth-service",
        namespace: "production",
        status: :completed,
        error: nil
      })

    graph =
      Ingestor.ingest(graph, %{
        service: "auth-service",
        namespace: "production",
        status: :completed,
        error: nil
      })

    graph =
      Ingestor.ingest(graph, %{
        service: "auth-service",
        namespace: "production",
        status: :completed,
        error: nil
      })

    # 2 failures for api-gateway
    graph =
      Ingestor.ingest(graph, %{
        service: "api-gateway",
        namespace: "staging",
        status: :failed,
        error: {:oom, "out of memory"}
      })

    graph =
      Ingestor.ingest(graph, %{
        service: "api-gateway",
        namespace: "staging",
        status: :failed,
        error: {:oom, "out of memory again"}
      })

    # 1 successful deploy for api-gateway too
    graph =
      Ingestor.ingest(graph, %{
        service: "api-gateway",
        namespace: "staging",
        status: :completed,
        error: nil
      })

    graph
  end

  describe "deploy_context/3" do
    test "returns context for known service" do
      graph = build_graph_with_history()
      ctx = Query.deploy_context(graph, "auth-service", "production")

      assert ctx.service == "auth-service"
      assert ctx.namespace == "production"
      assert ctx.known == true
    end

    test "returns context for unknown service" do
      graph = Graph.new()
      ctx = Query.deploy_context(graph, "new-service", "default")

      assert ctx.service == "new-service"
      assert ctx.namespace == "default"
      assert ctx.known == false
      assert ctx.failure_patterns == []
      assert ctx.dependencies == []
      assert ctx.recommendations == []
    end

    test "includes dependencies" do
      graph = build_graph_with_history()
      ctx = Query.deploy_context(graph, "auth-service", "production")

      # Should have depends_on relationship to namespace
      assert length(ctx.dependencies) >= 1
      ns_dep = Enum.find(ctx.dependencies, fn d -> String.contains?(d.target, "namespace:") end)
      assert ns_dep != nil
    end
  end

  describe "failure_patterns/2" do
    test "returns failure patterns for a service with failures" do
      graph = build_graph_with_history()
      service_id = Identity.compute_id(:concept, "api-gateway")

      patterns = Query.failure_patterns(graph, service_id)
      assert length(patterns) == 1

      [pattern] = patterns
      assert pattern.error == "oom"
      assert pattern.observations == 2
      assert pattern.confidence > 0
    end

    test "returns empty list for service with no failures" do
      graph = build_graph_with_history()
      service_id = Identity.compute_id(:concept, "auth-service")

      patterns = Query.failure_patterns(graph, service_id)
      assert patterns == []
    end

    test "sorts patterns by confidence descending" do
      graph = Graph.new()

      # Multiple different errors
      graph =
        Ingestor.ingest(graph, %{
          service: "svc",
          namespace: "ns",
          status: :failed,
          error: "error_a"
        })

      graph =
        Ingestor.ingest(graph, %{
          service: "svc",
          namespace: "ns",
          status: :failed,
          error: "error_a"
        })

      graph =
        Ingestor.ingest(graph, %{
          service: "svc",
          namespace: "ns",
          status: :failed,
          error: "error_a"
        })

      graph =
        Ingestor.ingest(graph, %{
          service: "svc",
          namespace: "ns",
          status: :failed,
          error: "error_b"
        })

      service_id = Identity.compute_id(:concept, "svc")
      patterns = Query.failure_patterns(graph, service_id)

      assert length(patterns) == 2
      [first, second] = patterns
      assert first.confidence >= second.confidence
    end
  end

  describe "dependencies/2" do
    test "returns namespace dependency" do
      graph =
        Ingestor.ingest(Graph.new(), %{
          service: "web-app",
          namespace: "prod",
          status: :completed,
          error: nil
        })

      service_id = Identity.compute_id(:concept, "web-app")
      deps = Query.dependencies(graph, service_id)

      assert length(deps) == 1
      [dep] = deps
      assert dep.target == "namespace:prod"
    end
  end

  describe "recommendations/3" do
    test "recommends canary for high failure rate" do
      graph = Graph.new()

      # EWMA starts at 0.5, alpha=0.3. Need ~5 reinforcements at 0.8 to cross 0.7:
      # 0.5 → 0.59 → 0.653 → 0.697 → 0.728 → 0.749
      # Recommendations require confidence > 0.7 AND observations >= 2
      result = %{service: "risky-svc", namespace: "prod", status: :failed, error: "crash"}
      graph = Enum.reduce(1..5, graph, fn _, g -> Ingestor.ingest(g, result) end)

      service_id = Identity.compute_id(:concept, "risky-svc")
      recs = Query.recommendations(graph, service_id)

      assert length(recs) >= 1
      assert Enum.any?(recs, fn r -> String.contains?(r, "canary") end)
    end

    test "no recommendations for healthy service" do
      graph =
        Ingestor.ingest(Graph.new(), %{
          service: "stable-svc",
          namespace: "prod",
          status: :completed,
          error: nil
        })

      service_id = Identity.compute_id(:concept, "stable-svc")
      recs = Query.recommendations(graph, service_id)

      assert recs == []
    end
  end
end

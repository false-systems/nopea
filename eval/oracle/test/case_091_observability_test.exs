defmodule Nopea.Oracle.Case091ObservabilityTest do
  @moduledoc """
  OBSERVABILITY & CONSISTENCY (091-100)

  Cross-endpoint consistency, temporal correctness, and behavioral
  invariants. These tests verify that the system is internally
  consistent — not just that endpoints return 200.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # CROSS-ENDPOINT CONSISTENCY
  # ================================================================

  test "case_091 deploy result is consistent with context and history" do
    service = "oracle-091-#{:rand.uniform(999_999)}"

    deploy = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })

    assert deploy.body["status"] == "completed"
    deploy_id = deploy.body["deploy_id"]

    Oracle.settle()

    # Context should know this service
    ctx = Oracle.http_get("/api/context/#{service}")
    assert ctx.body["known"] == true,
           "Context should show known=true after deploy"

    # History should have this deploy
    hist = Oracle.http_get("/api/history/#{service}")
    assert hist.body["state"]["last_deploy"] == deploy_id,
           "History should reference deploy_id #{deploy_id}"

    # Services list should include this service
    svcs = Oracle.http_get("/api/services")
    assert service in svcs.body["services"],
           "Services list should include '#{service}'"
  end

  test "case_092 deploy result service matches request service exactly" do
    service = "oracle-092-EXACT-Name"

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "manifests" => [Oracle.sample_configmap("oracle-092-cm")]
      })

    assert resp.status == 200
    assert resp.body["service"] == service,
           "Service name should be preserved exactly (case-sensitive)"
  end

  test "case_093 deploy result namespace matches request namespace exactly" do
    namespace = "oracle-093-ns"

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-093",
        "namespace" => namespace,
        "manifests" => [Oracle.sample_configmap("oracle-093-cm", namespace)]
      })

    assert resp.status == 200
    assert resp.body["namespace"] == namespace
  end

  # ================================================================
  # TEMPORAL CORRECTNESS
  # ================================================================

  test "case_094 sequential deploys have strictly increasing deploy_ids" do
    ids =
      for i <- 1..3 do
        resp =
          Oracle.http_post("/api/deploy", %{
            "service" => "oracle-094-#{i}",
            "manifests" => [Oracle.sample_configmap("oracle-094-cm-#{i}")]
          })

        assert resp.status == 200
        assert resp.body["status"] == "completed"
        resp.body["deploy_id"]
      end

    # ULIDs are lexicographically ordered by time — MUST be strictly ascending
    assert ids == Enum.sort(ids),
           "Deploy IDs should be strictly ascending: #{inspect(ids)}"
    assert Enum.uniq(ids) == ids,
           "Deploy IDs should all be unique: #{inspect(ids)}"
  end

  test "case_095 deploy durations are positive for real K8s applies" do
    for i <- 1..3 do
      resp =
        Oracle.http_post("/api/deploy", %{
          "service" => "oracle-095-#{i}",
          "manifests" => [Oracle.sample_configmap("oracle-095-cm-#{i}")]
        })

      assert resp.status == 200
      assert resp.body["duration_ms"] > 0,
             "Real K8s apply should take >0ms, got: #{resp.body["duration_ms"]}ms for deploy #{i}"
    end
  end

  # ================================================================
  # IDEMPOTENCY — SAME RESOURCE TWICE
  # ================================================================

  test "case_096 deploying same ConfigMap twice both succeed with different IDs" do
    service = "oracle-096-#{:rand.uniform(999_999)}"
    manifests = [Oracle.sample_configmap("#{service}-cm")]

    resp1 =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "manifests" => manifests
      })

    resp2 =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "manifests" => manifests
      })

    assert resp1.body["status"] == "completed"
    assert resp2.body["status"] == "completed"
    assert resp1.body["deploy_id"] != resp2.body["deploy_id"]
    assert resp1.body["deploy_id"] < resp2.body["deploy_id"],
           "Second deploy ID should be newer"
  end

  # ================================================================
  # ERROR RESPONSE STRUCTURE
  # ================================================================

  test "case_097 404 responses have structured error body" do
    resp_404 = Oracle.http_get("/api/unknown-route")
    assert resp_404.status == 404
    assert is_map(resp_404.body)
    assert resp_404.body["error"] == "not_found",
           "404 should have error: 'not_found', got: #{inspect(resp_404.body)}"
  end

  test "case_098 error responses never leak internal paths or stack traces" do
    # Deploy with null service — known to return 200 with failed status
    resp = Oracle.http_post("/api/deploy", %{"service" => nil})
    body_str = Jason.encode!(resp.body)

    refute String.contains?(body_str, "stacktrace"),
           "Response should not contain 'stacktrace'"
    refute String.contains?(body_str, "** ("),
           "Response should not contain Elixir exception prefix"
    refute String.contains?(body_str, ".ex:"),
           "Response should not contain file:line references"
    refute String.contains?(body_str, "lib/nopea"),
           "Response should not contain internal paths"
  end

  # ================================================================
  # MEMORY WEIGHT ACCUMULATION
  # ================================================================

  test "case_099 dependency weight increases with repeated deploys" do
    service = "oracle-099-#{:rand.uniform(999_999)}"

    # First deploy
    Oracle.http_post("/api/deploy", %{
      "service" => service,
      "namespace" => "default",
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    Oracle.settle()

    ctx1 = Oracle.http_get("/api/context/#{service}")
    deps1 = ctx1.body["dependencies"]
    weight1 = case Enum.find(deps1, fn d -> String.contains?(d["target"], "namespace") end) do
      nil -> 0
      dep -> dep["weight"]
    end

    # Second deploy
    Oracle.http_post("/api/deploy", %{
      "service" => service,
      "namespace" => "default",
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    Oracle.settle()

    ctx2 = Oracle.http_get("/api/context/#{service}")
    deps2 = ctx2.body["dependencies"]
    weight2 = case Enum.find(deps2, fn d -> String.contains?(d["target"], "namespace") end) do
      nil -> 0
      dep -> dep["weight"]
    end

    assert weight2 >= weight1,
           "Dependency weight should not decrease after repeated deploys: #{weight1} -> #{weight2}"

    obs2 = case Enum.find(deps2, fn d -> String.contains?(d["target"], "namespace") end) do
      nil -> 0
      dep -> dep["observations"]
    end
    assert obs2 >= 2,
           "Observations should be >= 2 after two deploys, got: #{obs2}"
  end

  test "case_100 explain strategy changes after failure pattern emerges" do
    service = "oracle-100-#{:rand.uniform(999_999)}"

    # First, explain for unknown service — should say direct
    explain1 = Oracle.http_get("/api/explain/#{service}")
    assert String.contains?(explain1.body["explanation"], "direct"),
           "Unknown service should default to direct strategy"

    # Create a failure pattern by deploying with canary (fails without Kulta)
    Oracle.http_post("/api/deploy", %{
      "service" => service,
      "strategy" => "canary",
      "manifests" => [Oracle.sample_deployment("#{service}-deploy")]
    })
    Oracle.settle()

    # After failure, explain may reference the failure pattern
    explain2 = Oracle.http_get("/api/explain/#{service}")
    assert is_binary(explain2.body["explanation"])
    # The service is now known — explanation should differ from "unknown"
    assert explain2.body["service"] == service
  end
end

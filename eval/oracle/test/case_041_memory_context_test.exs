defmodule Nopea.Oracle.Case041MemoryContextTest do
  @moduledoc """
  MEMORY & CONTEXT (041-050)

  Tests the knowledge graph query path. Nopea's core innovation
  is memory — these tests verify the system actually learns from
  deploys and provides accurate context. Not happy path.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # CONTEXT FOR UNKNOWN SERVICES
  # ================================================================

  test "case_041 context for unknown service returns known: false with empty patterns" do
    service = "oracle-041-unknown-#{:rand.uniform(999_999)}"
    resp = Oracle.http_get("/api/context/#{service}")
    assert resp.status == 200
    assert resp.body["known"] == false
    assert resp.body["failure_patterns"] == [],
           "Unknown service should have no failure patterns, got: #{inspect(resp.body["failure_patterns"])}"
    assert resp.body["dependencies"] == [],
           "Unknown service should have no dependencies, got: #{inspect(resp.body["dependencies"])}"
  end

  test "case_042 context response shape is complete" do
    resp = Oracle.http_get("/api/context/any-service-042")
    assert resp.status == 200

    body = resp.body
    assert Map.has_key?(body, "known"), "Missing 'known' key"
    assert Map.has_key?(body, "service"), "Missing 'service' key"
    assert Map.has_key?(body, "failure_patterns"), "Missing 'failure_patterns' key"
    assert Map.has_key?(body, "dependencies"), "Missing 'dependencies' key"
    assert Map.has_key?(body, "recommendations"), "Missing 'recommendations' key"
    assert is_boolean(body["known"])
    assert is_list(body["failure_patterns"])
    assert is_list(body["dependencies"])
    assert is_list(body["recommendations"])
  end

  test "case_043 context namespace parameter is passed through" do
    resp = Oracle.http_get("/api/context/svc-043?namespace=custom-ns")
    assert resp.status == 200
    assert resp.body["namespace"] == "custom-ns",
           "Namespace should be 'custom-ns', got: #{inspect(resp.body["namespace"])}"
  end

  # ================================================================
  # LEARNING — THE CORE ORACLE: DEPLOY THEN VERIFY MEMORY
  # ================================================================

  test "case_044 service becomes known: true after deploy" do
    service = "oracle-044-#{:rand.uniform(999_999)}"

    # Before deploy — must be unknown
    ctx_before = Oracle.http_get("/api/context/#{service}")
    assert ctx_before.body["known"] == false,
           "Fresh service should be unknown before deploy"

    # Deploy a real resource
    deploy = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    assert deploy.body["status"] == "completed"

    # Wait for async memory cast to process
    Oracle.settle()

    # After deploy — MUST be known
    ctx_after = Oracle.http_get("/api/context/#{service}")
    assert ctx_after.body["known"] == true,
           "Service should be known after successful deploy, got: #{inspect(ctx_after.body["known"])}"
  end

  test "case_045 dependency on namespace appears after deploy" do
    service = "oracle-045-#{:rand.uniform(999_999)}"

    Oracle.http_post("/api/deploy", %{
      "service" => service,
      "namespace" => "default",
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })

    Oracle.settle()

    ctx = Oracle.http_get("/api/context/#{service}")
    assert ctx.body["known"] == true

    deps = ctx.body["dependencies"]
    assert is_list(deps) and length(deps) > 0,
           "After deploy to 'default' namespace, should have at least one dependency, got: #{inspect(deps)}"

    ns_dep = Enum.find(deps, fn d -> String.contains?(d["target"], "namespace") end)
    assert ns_dep != nil,
           "Should have a namespace dependency, got deps: #{inspect(deps)}"
  end

  test "case_046 failure pattern emerges after failed canary deploy" do
    service = "oracle-046-#{:rand.uniform(999_999)}"

    # Canary deploy fails without Kulta — this creates a failure record
    resp = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "strategy" => "canary",
      "manifests" => [Oracle.sample_deployment("#{service}-deploy")]
    })
    assert resp.body["status"] == "failed"

    Oracle.settle()

    ctx = Oracle.http_get("/api/context/#{service}")
    assert ctx.body["known"] == true,
           "Failed deploy should still make service known"

    # After a failure, there should be failure patterns
    patterns = ctx.body["failure_patterns"]
    assert is_list(patterns) and length(patterns) > 0,
           "Failed canary deploy should create failure patterns, got: #{inspect(patterns)}"
  end

  # ================================================================
  # HISTORY — VERIFY DEPLOYS ARE RECORDED
  # ================================================================

  test "case_047 history shows state after deploy" do
    service = "oracle-047-#{:rand.uniform(999_999)}"

    deploy = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    assert deploy.body["status"] == "completed"
    deploy_id = deploy.body["deploy_id"]

    Oracle.settle()

    resp = Oracle.http_get("/api/history/#{service}")
    assert resp.status == 200

    state = resp.body["state"]
    assert state != nil, "History should have state after deploy"
    assert state["status"] == "completed"
    assert state["last_deploy"] == deploy_id,
           "History last_deploy should match, expected #{deploy_id}, got #{state["last_deploy"]}"
    assert state["last_deploy_at"] != nil
  end

  test "case_048 history updates after second deploy" do
    service = "oracle-048-#{:rand.uniform(999_999)}"

    deploy1 = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    id1 = deploy1.body["deploy_id"]

    Oracle.settle()

    deploy2 = Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })
    id2 = deploy2.body["deploy_id"]

    Oracle.settle()

    resp = Oracle.http_get("/api/history/#{service}")
    state = resp.body["state"]
    assert state["last_deploy"] == id2,
           "History should show latest deploy #{id2}, not #{id1}, got #{state["last_deploy"]}"
  end

  # ================================================================
  # EXPLAIN — STRATEGY REASONING
  # ================================================================

  test "case_049 explain includes service name and strategy reasoning" do
    service = "oracle-049"
    resp = Oracle.http_get("/api/explain/#{service}")
    assert resp.status == 200
    assert resp.body["service"] == service
    assert is_binary(resp.body["explanation"]),
           "Explanation should be a string, got: #{inspect(resp.body["explanation"])}"
    assert String.length(resp.body["explanation"]) > 10,
           "Explanation should be meaningful, got: #{resp.body["explanation"]}"
  end

  # ================================================================
  # SERVICES LIST — MUST REFLECT REALITY
  # ================================================================

  test "case_050 deployed service appears in services list" do
    service = "oracle-050-#{:rand.uniform(999_999)}"

    Oracle.http_post("/api/deploy", %{
      "service" => service,
      "manifests" => [Oracle.sample_configmap("#{service}-cm")]
    })

    Oracle.settle()

    resp = Oracle.http_get("/api/services")
    assert resp.status == 200
    assert service in resp.body["services"],
           "Deployed service '#{service}' should appear in services list, got: #{length(resp.body["services"])} services"
    assert resp.body["count"] == length(resp.body["services"]),
           "Count should match list length"
  end
end

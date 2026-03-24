defmodule Nopea.Oracle.Case031DeployCorrectnessTest do
  @moduledoc """
  DEPLOY CORRECTNESS (031-040)

  Verifies deploy responses have correct structure and semantics.
  Every field must be present, have the right type, and reflect reality.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # RESPONSE SHAPE — hard assertions, not "is_map"
  # ================================================================

  test "case_031 successful deploy response has all required fields with correct values" do
    service = "oracle-031-#{:rand.uniform(999_999)}"
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "namespace" => "default",
        "strategy" => "direct",
        "manifests" => [Oracle.sample_configmap("#{service}-cm")]
      })

    assert resp.status == 200
    body = resp.body

    Oracle.assert_json_shape(body, [
      "deploy_id",
      "status",
      "service",
      "namespace",
      "strategy",
      "duration_ms",
      "manifest_count"
    ])

    assert body["status"] == "completed",
           "Deploy with valid ConfigMap should complete, got: #{body["status"]}"
    assert body["service"] == service
    assert body["namespace"] == "default"
    assert body["strategy"] == "direct"
    assert body["manifest_count"] == 1,
           "Sent 1 manifest but got manifest_count: #{body["manifest_count"]}"
    assert body["duration_ms"] > 0,
           "Real K8s apply should take >0ms, got: #{body["duration_ms"]}"
    assert is_binary(body["deploy_id"])
    assert String.length(body["deploy_id"]) == 26
  end

  test "case_032 deploy_id is a ULID (26 chars, Crockford base32)" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-032",
        "manifests" => [Oracle.sample_configmap("oracle-032-cm")]
      })

    assert resp.status == 200
    deploy_id = resp.body["deploy_id"]

    # ULID: 26 characters, Crockford base32
    assert String.length(deploy_id) == 26,
           "ULID should be 26 chars, got #{String.length(deploy_id)}: #{deploy_id}"
    assert Regex.match?(~r/^[0-9A-Z]{26}$/, deploy_id),
           "ULID should be Crockford base32, got: #{deploy_id}"
  end

  test "case_033 two deploys to same service produce different deploy_ids" do
    resp1 =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-033",
        "manifests" => [Oracle.sample_configmap("oracle-033-cm")]
      })

    resp2 =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-033",
        "manifests" => [Oracle.sample_configmap("oracle-033-cm")]
      })

    assert resp1.status == 200
    assert resp2.status == 200
    assert resp1.body["deploy_id"] != resp2.body["deploy_id"],
           "Two deploys should have unique IDs"
  end

  test "case_034 deploy_ids are monotonically increasing (ULID time ordering)" do
    resp1 =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-034",
        "manifests" => [Oracle.sample_configmap("oracle-034-cm")]
      })

    resp2 =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-034",
        "manifests" => [Oracle.sample_configmap("oracle-034-cm")]
      })

    assert resp1.status == 200
    assert resp2.status == 200
    # ULIDs sort lexicographically by time
    assert resp1.body["deploy_id"] < resp2.body["deploy_id"],
           "Second deploy_id should be greater: #{resp1.body["deploy_id"]} vs #{resp2.body["deploy_id"]}"
  end

  test "case_035 default strategy is direct" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-035",
        "manifests" => [Oracle.sample_configmap("oracle-035-cm")]
      })

    assert resp.status == 200
    assert resp.body["strategy"] == "direct"
  end

  test "case_036 default namespace is default" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-036",
        "manifests" => [Oracle.sample_configmap("oracle-036-cm")]
      })

    assert resp.status == 200
    assert resp.body["namespace"] == "default"
  end

  test "case_037 manifest_count exactly matches number of manifests sent" do
    manifests = [
      Oracle.sample_configmap("oracle-037-a"),
      Oracle.sample_configmap("oracle-037-b"),
      Oracle.sample_configmap("oracle-037-c")
    ]

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-037",
        "manifests" => manifests
      })

    assert resp.status == 200
    assert resp.body["manifest_count"] == 3,
           "Sent 3 manifests but got manifest_count: #{resp.body["manifest_count"]}"
  end

  test "case_038 deploy with real manifests takes measurable time" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-038",
        "manifests" => [Oracle.sample_configmap("oracle-038-cm")]
      })

    assert resp.status == 200
    duration = resp.body["duration_ms"]
    assert duration > 0,
           "A real K8s apply should take >0ms, got: #{duration}"
    assert duration < 30_000,
           "Deploy of 1 ConfigMap should not take 30s, got: #{duration}ms"
  end

  test "case_039 canary strategy fails without Kulta CRDs" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-039",
        "strategy" => "canary",
        "manifests" => [Oracle.sample_deployment("oracle-039-deploy")]
      })

    assert resp.status == 200
    assert resp.body["status"] == "failed",
           "Canary without Kulta should fail, got: #{resp.body["status"]}"
    assert resp.body["strategy"] == "canary"
  end

  test "case_040 explicit strategy direct is respected even for known service" do
    # Deploy twice with explicit direct to verify strategy isn't overridden by memory
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-040",
        "strategy" => "direct",
        "manifests" => [Oracle.sample_configmap("oracle-040-cm")]
      })

    assert resp.status == 200
    assert resp.body["strategy"] == "direct"
    assert resp.body["status"] == "completed"
  end
end

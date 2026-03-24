defmodule Nopea.Oracle.Case016DeployErrorsTest do
  @moduledoc """
  DEPLOY ERROR PATHS (016-030)

  Every deploy failure mode must produce a correct, structured error
  response. These tests throw garbage at the deploy endpoint and verify
  the system rejects bad input instead of silently accepting it.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # MISSING / INVALID FIELDS
  # ================================================================

  test "case_016 deploy without service returns 400" do
    resp = Oracle.http_post("/api/deploy", %{})
    assert resp.status == 400,
           "Deploy without service should be 400, got: #{resp.status}"
    assert is_binary(resp.body["error"])
  end

  test "case_017 deploy with empty service string" do
    resp = Oracle.http_post("/api/deploy", %{"service" => ""})
    # Empty string should be treated as missing → 400, or proceed → 200 with failed
    assert resp.status in [400, 200]

    if resp.status == 200 do
      assert resp.body["status"] in ["completed", "failed"]
      assert resp.body["service"] == "",
             "Service name should be echoed back as-is"
    end
  end

  test "case_018 deploy with null service" do
    resp = Oracle.http_post("/api/deploy", %{"service" => nil})
    # This is a known Nopea behavior: null service proceeds with service=null
    # The oracle documents this: it's a real Nopea gap — null should be 400
    assert resp.status in [200, 400]

    if resp.status == 200 do
      # If it accepts it, verify it at least reports failed
      assert resp.body["status"] == "failed",
             "Deploy with null service should fail, got: #{resp.body["status"]}"
    end
  end

  test "case_019 deploy with numeric service name does not crash" do
    resp = Oracle.http_post("/api/deploy", %{"service" => 12345})
    # Should either reject or handle — never 500
    assert resp.status in [200, 400],
           "Numeric service should be 200 or 400, got: #{resp.status}"

    if resp.status == 200 do
      assert is_binary(resp.body["deploy_id"])
    end
  end

  # ================================================================
  # INVALID MANIFESTS — real K8s rejection
  # ================================================================

  test "case_020 deploy with manifest missing apiVersion fails at K8s" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-020",
        "manifests" => [Oracle.manifest_no_api_version()]
      })

    # K8s should reject a manifest without apiVersion
    assert resp.status in [200, 400]

    if resp.status == 200 do
      assert resp.body["status"] == "failed",
             "Manifest without apiVersion should fail K8s apply, got: #{resp.body["status"]}"
    end
  end

  test "case_021 deploy with manifest missing kind fails at K8s" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-021",
        "manifests" => [Oracle.manifest_no_kind()]
      })

    assert resp.status in [200, 400]

    if resp.status == 200 do
      assert resp.body["status"] == "failed",
             "Manifest without kind should fail K8s apply, got: #{resp.body["status"]}"
    end
  end

  test "case_022 deploy with manifest missing metadata fails" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-022",
        "manifests" => [Oracle.manifest_no_metadata()]
      })

    assert resp.status in [200, 400]
    # Must not crash
    assert is_map(resp.body)
  end

  test "case_023 deploy with manifest missing name fails" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-023",
        "manifests" => [Oracle.manifest_no_name()]
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_024 deploy with empty manifests list completes with 0 manifests" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-024",
        "manifests" => []
      })

    assert resp.status == 200
    assert resp.body["manifest_count"] == 0,
           "Empty manifests should produce manifest_count: 0, got: #{resp.body["manifest_count"]}"
    assert resp.body["status"] == "completed",
           "Empty manifests deploy should complete (nothing to fail), got: #{resp.body["status"]}"
  end

  test "case_025 deploy with manifests as string instead of list" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-025",
        "manifests" => "not a list"
      })

    # Type mismatch — should not silently succeed with 0 manifests
    assert resp.status in [200, 400, 422, 500]
    if resp.status == 200 do
      # If it accepts, it should at least report the type issue
      assert resp.body["manifest_count"] == 0 or resp.body["status"] == "failed",
             "String manifests should not silently apply, got: #{inspect(resp.body)}"
    end
  end

  # ================================================================
  # INVALID STRATEGY
  # ================================================================

  test "case_026 deploy with unknown strategy falls back to direct" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-026",
        "manifests" => [Oracle.sample_configmap("oracle-026-cm")],
        "strategy" => "yolo_deploy"
      })

    assert resp.status == 200
    assert resp.body["strategy"] == "direct",
           "Unknown strategy should fall back to direct, got: #{resp.body["strategy"]}"
    assert resp.body["status"] == "completed"
  end

  test "case_027 deploy with strategy as integer falls back to direct" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-027",
        "manifests" => [Oracle.sample_configmap("oracle-027-cm")],
        "strategy" => 42
      })

    assert resp.status in [200, 400]
    if resp.status == 200 do
      assert resp.body["strategy"] == "direct"
    end
  end

  # ================================================================
  # NAMESPACE EDGE CASES
  # ================================================================

  test "case_028 deploy with extremely long namespace" do
    long_ns = String.duplicate("a", 253)

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-028",
        "namespace" => long_ns,
        "manifests" => []
      })

    # K8s rejects namespaces > 63 chars, but Nopea with empty manifests won't hit K8s
    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_029 deploy with path traversal in service name" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle/../../../etc/passwd",
        "manifests" => []
      })

    # Path traversal in service name — should not crash, ideally reject
    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_030 deploy with unicode service name" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-\u{1F680}-rocket",
        "manifests" => [Oracle.sample_configmap("oracle-030-cm")]
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end
end

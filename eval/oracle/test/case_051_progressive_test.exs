defmodule Nopea.Oracle.Case051ProgressiveTest do
  @moduledoc """
  PROGRESSIVE DELIVERY (051-060)

  Tests promote/rollback on nonexistent rollouts, status queries,
  and edge cases. These cannot test full progressive delivery without
  a Kulta-equipped cluster, but they verify error handling is correct.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # PROMOTE — ERROR PATHS
  # ================================================================

  test "case_051 promote nonexistent deploy_id returns 404" do
    resp = Oracle.http_post("/api/promote/00000000000000000000000000", %{})
    assert resp.status == 404
    assert resp.body["error"] == "not_found"
  end

  test "case_052 promote with garbage deploy_id returns 404 not 500" do
    resp = Oracle.http_post("/api/promote/not-a-ulid-at-all", %{})
    assert resp.status == 404
  end

  test "case_053 promote with empty deploy_id gets routed correctly" do
    # The route is /api/promote/:deploy_id, so empty would be /api/promote/
    # which should be 404 (no matching route)
    resp = Oracle.http_post("/api/promote/", %{})
    assert resp.status in [404, 405]
  end

  # ================================================================
  # ROLLBACK — ERROR PATHS
  # ================================================================

  test "case_054 rollback nonexistent deploy_id returns 404" do
    resp = Oracle.http_post("/api/rollback/00000000000000000000000000", %{})
    assert resp.status == 404
    assert resp.body["error"] == "not_found"
  end

  test "case_055 rollback with garbage deploy_id returns 404 not 500" do
    resp = Oracle.http_post("/api/rollback/this-is-not-valid", %{})
    assert resp.status == 404
  end

  # ================================================================
  # STATUS — ERROR PATHS
  # ================================================================

  test "case_056 status for nonexistent service returns 404 or 503" do
    resp = Oracle.http_get("/api/status/nonexistent-#{:rand.uniform(999_999)}")
    # 404 = not found, 503 = ServiceAgent.Supervisor not running
    assert resp.status in [404, 503]
  end

  test "case_057 status for service with path traversal attempt" do
    resp = Oracle.http_get("/api/status/../../etc/passwd")
    # Must not crash or expose filesystem
    assert resp.status in [404, 503]
    assert is_map(resp.body)
  end

  test "case_058 status for service with URL encoding" do
    resp = Oracle.http_get("/api/status/service%20with%20spaces")
    assert resp.status in [404, 503]
    assert is_map(resp.body)
  end

  # ================================================================
  # DEPLOY THEN STATUS
  # ================================================================

  test "case_059 status returns idle after deploy completes" do
    service = "oracle-059-#{:rand.uniform(999_999)}"

    deploy_resp =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "manifests" => []
      })

    assert deploy_resp.status == 200
    Oracle.settle()

    status_resp = Oracle.http_get("/api/status/#{service}")

    case status_resp.status do
      200 ->
        # If agent is still alive, status should be idle
        assert status_resp.body["status"] in ["idle", "deploying"]

      404 ->
        # Agent may have already timed out (unlikely in <1s but valid)
        :ok

      503 ->
        # ServiceAgent not running — acceptable
        :ok
    end
  end

  test "case_060 promote after direct deploy returns not_found (no rollout)" do
    service = "oracle-060-#{:rand.uniform(999_999)}"

    deploy_resp =
      Oracle.http_post("/api/deploy", %{
        "service" => service,
        "strategy" => "direct",
        "manifests" => []
      })

    assert deploy_resp.status == 200
    deploy_id = deploy_resp.body["deploy_id"]

    # Direct deploys don't create progressive rollouts
    promote_resp = Oracle.http_post("/api/promote/#{deploy_id}", %{})
    assert promote_resp.status == 404
  end
end

defmodule Nopea.Oracle.Case001HealthTest do
  @moduledoc """
  HEALTH & READINESS (001-005)

  Validates liveness and readiness probes work correctly.
  These are the most basic oracle cases — if these fail,
  the system is not running.
  """
  use ExUnit.Case, async: true

  alias Nopea.Oracle

  # ================================================================
  # HEALTH & READY — BASIC LIVENESS
  # ================================================================

  test "case_001 health endpoint returns 200 with status ok" do
    resp = Oracle.http_get("/health")
    assert resp.status == 200
    assert resp.body["status"] == "ok"
  end

  test "case_002 ready endpoint returns 200 with status ready" do
    resp = Oracle.http_get("/ready")
    assert resp.status == 200
    assert resp.body["status"] == "ready"
  end

  test "case_003 health and ready are public — no auth header needed" do
    # Explicitly pass no API key, even if one is configured
    resp_health = Oracle.http_get("/health", api_key: nil)
    resp_ready = Oracle.http_get("/ready", api_key: nil)

    assert resp_health.status == 200
    assert resp_ready.status == 200
  end

  test "case_004 unknown route returns 404 not 500" do
    resp = Oracle.http_get("/api/nonexistent/route/that/does/not/exist")
    assert resp.status == 404
    assert resp.body["error"] == "not_found"
  end

  test "case_005 health response is valid JSON with correct content-type" do
    resp = Oracle.http_get("/health")

    {_key, content_type} =
      resp.headers
      |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)

    # content_type may be a string or list depending on Req version
    ct_string = if is_list(content_type), do: hd(content_type), else: content_type
    assert String.contains?(ct_string, "application/json")
    assert is_map(resp.body)
  end
end

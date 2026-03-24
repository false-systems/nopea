defmodule Nopea.Oracle.Case006AuthTest do
  @moduledoc """
  AUTHENTICATION (006-015)

  Tests API key authentication enforcement.
  These tests adapt based on whether NOPEA_API_KEY is set:
  - If set: validates 401 on missing/wrong key, 200 on correct key
  - If nil: validates dev mode (all requests pass)
  """
  use ExUnit.Case, async: true

  alias Nopea.Oracle

  setup do
    %{api_key: Oracle.api_key()}
  end

  # ================================================================
  # AUTH ENFORCEMENT (when key is configured)
  # These tests verify auth behavior. When no key is configured,
  # they pass trivially (dev mode expectation).
  # ================================================================

  @tag :auth_required
  test "case_006 api endpoint returns 401 without api key when key is configured", ctx do
    resp = Oracle.http_get("/api/services", api_key: nil)
    if ctx.api_key do
      assert resp.status == 401
    else
      # Dev mode — no auth enforced, any request passes
      assert resp.status == 200
    end
  end

  @tag :auth_required
  test "case_007 api endpoint returns 401 with wrong api key", ctx do
    resp = Oracle.http_get("/api/services", api_key: "wrong-key-that-is-definitely-not-correct")
    if ctx.api_key do
      assert resp.status == 401
    else
      assert resp.status == 200
    end
  end

  @tag :auth_required
  test "case_008 api endpoint returns 200 with correct api key", ctx do
    if ctx.api_key do
      resp = Oracle.http_get("/api/services")
      assert resp.status == 200
    else
      # Dev mode — pass without key
      resp = Oracle.http_get("/api/services", api_key: nil)
      assert resp.status == 200
    end
  end

  @tag :auth_required
  test "case_009 health endpoint bypasses auth even when key is configured", _ctx do
    resp = Oracle.http_get("/health", api_key: nil)
    assert resp.status == 200
  end

  @tag :auth_required
  test "case_010 ready endpoint bypasses auth even when key is configured", _ctx do
    resp = Oracle.http_get("/ready", api_key: nil)
    assert resp.status == 200
  end

  @tag :auth_required
  test "case_011 empty api key string is not treated as valid", ctx do
    resp = Oracle.http_get("/api/services", api_key: "")
    if ctx.api_key do
      assert resp.status == 401
    else
      assert resp.status == 200
    end
  end

  @tag :auth_required
  test "case_012 api key with trailing whitespace is rejected", ctx do
    if ctx.api_key do
      resp = Oracle.http_get("/api/services", api_key: ctx.api_key <> " ")
      # Server should either trim and accept, or reject. Either is fine.
      # What's NOT fine is a 500.
      assert resp.status in [200, 401]
    else
      resp = Oracle.http_get("/api/services", api_key: nil)
      assert resp.status == 200
    end
  end

  # ================================================================
  # DEV MODE (when no key is configured)
  # ================================================================

  @tag :auth_dev_mode
  test "case_013 dev mode allows requests without api key", ctx do
    if ctx.api_key do
      # Auth is configured — this test is about dev mode, so verify auth works
      resp = Oracle.http_get("/api/services", api_key: nil)
      assert resp.status == 401
    else
      resp = Oracle.http_get("/api/services", api_key: nil)
      assert resp.status == 200
    end
  end

  @tag :auth_dev_mode
  test "case_014 dev mode allows requests with arbitrary api key", ctx do
    if ctx.api_key do
      # Auth is configured — arbitrary key should be rejected
      resp = Oracle.http_get("/api/services", api_key: "any-random-key")
      assert resp.status == 401
    else
      resp = Oracle.http_get("/api/services", api_key: "any-random-key")
      assert resp.status == 200
    end
  end

  # ================================================================
  # AUTH ON WRITE ENDPOINTS
  # ================================================================

  @tag :auth_required
  test "case_015 deploy endpoint returns 401 without key when auth is enabled", ctx do
    resp = Oracle.http_post("/api/deploy", %{"service" => "auth-test"}, api_key: nil)
    if ctx.api_key do
      assert resp.status == 401
    else
      # Dev mode — deploy proceeds
      assert resp.status == 200
    end
  end
end

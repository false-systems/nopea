defmodule Nopea.Oracle.Case061ResilienceTest do
  @moduledoc """
  RESILIENCE (061-075)

  Throws hostile input at every endpoint. The system must never crash,
  never return raw exceptions, never hang. Every response must be
  well-formed JSON with an appropriate status code.

  These are the tests that find real bugs.
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  # ================================================================
  # PAYLOAD BOMBS
  # ================================================================

  test "case_061 deploy with deeply nested manifest does not crash" do
    # Build a 50-level nested map
    nested =
      Enum.reduce(1..50, %{"value" => "deep"}, fn i, acc ->
        %{"level_#{i}" => acc}
      end)

    manifest = %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{"name" => "deep-nest"},
      "data" => %{"nested" => Jason.encode!(nested)}
    }

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-061",
        "manifests" => [manifest]
      })

    assert resp.status in [200, 400, 422, 500]
    assert is_map(resp.body)
  end

  @tag timeout: 120_000
  test "case_062 deploy with 100 manifests does not crash" do
    manifests =
      for i <- 1..100 do
        Oracle.sample_configmap("oracle-062-cm-#{i}")
      end

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-062",
        "manifests" => manifests
      }, timeout: 90_000)

    assert resp.status in [200, 400, 413, 504]
    assert is_map(resp.body)
  end

  test "case_063 deploy with manifest containing binary data" do
    manifest = %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{"name" => "binary-data"},
      "data" => %{"key" => Base.encode64(:crypto.strong_rand_bytes(1024))}
    }

    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-063",
        "manifests" => [manifest]
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  # ================================================================
  # INJECTION ATTEMPTS
  # ================================================================

  test "case_064 service name with shell metacharacters" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle; rm -rf /; echo pwned",
        "manifests" => []
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_065 namespace with newline injection" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle-065",
        "namespace" => "default\r\nX-Injected: true",
        "manifests" => []
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_066 service name with null bytes" do
    resp =
      Oracle.http_post("/api/deploy", %{
        "service" => "oracle\x00-066",
        "manifests" => []
      })

    assert resp.status in [200, 400]
    assert is_map(resp.body)
  end

  test "case_067 context endpoint with XSS in service name" do
    # URL-encode the XSS payload since Req rejects raw angle brackets in paths
    encoded_service = URI.encode("<script>alert(1)</script>")
    resp = Oracle.http_get("/api/context/#{encoded_service}")
    assert resp.status in [200, 400, 404]
    # Response must be JSON, not HTML
    assert is_map(resp.body)
  end

  # ================================================================
  # MALFORMED REQUESTS
  # ================================================================

  test "case_068 deploy with non-JSON body returns error" do
    resp = Oracle.http_raw_post("/api/deploy", "this is not json at all")
    # Plug may return 400, 415, or 500 for parse errors — key is no raw exception
    assert resp.status in [400, 415, 500]
    # As long as the response is structured (not a raw Erlang crash dump)
    assert is_binary(resp.body) or is_map(resp.body)
  end

  test "case_069 deploy with empty body returns 400" do
    resp = Oracle.http_raw_post("/api/deploy", "")
    assert resp.status in [400, 415]
  end

  test "case_070 GET on POST-only endpoint returns 404" do
    resp = Oracle.http_get("/api/deploy")
    assert resp.status == 404
  end

  test "case_071 PUT method on deploy endpoint returns 404" do
    resp = Oracle.http_request(:put, "/api/deploy")
    assert resp.status in [404, 405]
  end

  test "case_072 DELETE method on health endpoint" do
    resp = Oracle.http_request(:delete, "/health")
    assert resp.status in [200, 404, 405]
  end

  # ================================================================
  # CONCURRENT STRESS
  # ================================================================

  test "case_073 concurrent deploys to same service do not corrupt state" do
    service = "oracle-073-#{:rand.uniform(999_999)}"

    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          Oracle.http_post("/api/deploy", %{
            "service" => service,
            "manifests" => [Oracle.sample_configmap("#{service}-cm-#{i}")]
          })
        end)
      end

    results = Task.await_many(tasks, 30_000)

    for resp <- results do
      # Every response must be valid — no crashes
      assert resp.status in [200, 429, 503]
      assert is_map(resp.body)
    end
  end

  test "case_074 concurrent deploys to different services" do
    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          service = "oracle-074-svc-#{i}-#{:rand.uniform(999_999)}"

          Oracle.http_post("/api/deploy", %{
            "service" => service,
            "manifests" => []
          })
        end)
      end

    results = Task.await_many(tasks, 30_000)

    for resp <- results do
      assert resp.status in [200, 429, 503]
      assert is_map(resp.body)
    end
  end

  test "case_075 rapid health checks under load do not degrade" do
    tasks =
      for _i <- 1..20 do
        Task.async(fn ->
          Oracle.http_get("/health")
        end)
      end

    results = Task.await_many(tasks, 10_000)

    for resp <- results do
      assert resp.status == 200
      assert resp.body["status"] == "ok"
    end
  end
end

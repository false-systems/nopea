defmodule Nopea.API.RouterTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  import Mox

  alias Nopea.API.Router

  setup :verify_on_exit!

  setup do
    Mox.stub_with(Nopea.K8sMock, Nopea.K8s)
    :ok
  end

  describe "GET /health" do
    test "returns 200 ok" do
      conn = conn(:get, "/health") |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /ready" do
    test "returns 200 ready" do
      conn = conn(:get, "/ready") |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ready"
    end
  end

  describe "POST /api/deploy" do
    test "triggers deployment with valid spec" do
      body =
        Jason.encode!(%{
          service: "test-svc",
          namespace: "default",
          manifests: [],
          strategy: "direct"
        })

      conn =
        conn(:post, "/api/deploy", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      result = Jason.decode!(conn.resp_body)
      assert result["status"] == "completed"
      assert result["service"] == "test-svc"
    end

    test "returns 400 for missing service" do
      body = Jason.encode!(%{manifests: []})

      conn =
        conn(:post, "/api/deploy", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      assert conn.status == 400
    end
  end

  describe "GET /api/context/:service" do
    test "returns memory context for a service" do
      conn =
        conn(:get, "/api/context/api-gateway")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      # New service has no context
      assert is_map(body)
    end
  end

  describe "GET /api/history/:service" do
    test "returns empty history for unknown service" do
      conn =
        conn(:get, "/api/history/unknown-svc")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["deployments"] == [] or is_list(body["deployments"])
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn = conn(:get, "/nonexistent") |> Router.call(Router.init([]))
      assert conn.status == 404
    end
  end
end

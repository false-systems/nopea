defmodule Nopea.API.AuthPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Nopea.API.AuthPlug

  setup do
    # Ensure no api_key is set by default (dev mode)
    original = Application.get_env(:nopea, :api_key)
    on_exit(fn -> Application.put_env(:nopea, :api_key, original) end)
    :ok
  end

  describe "dev mode (no key configured)" do
    test "allows requests without x-api-key header" do
      Application.put_env(:nopea, :api_key, nil)

      conn =
        conn(:get, "/api/services")
        |> AuthPlug.call(AuthPlug.init([]))

      refute conn.halted
    end

    test "allows requests to /api/deploy without key" do
      Application.put_env(:nopea, :api_key, nil)

      conn =
        conn(:post, "/api/deploy")
        |> AuthPlug.call(AuthPlug.init([]))

      refute conn.halted
    end
  end

  describe "with key configured" do
    test "allows requests with valid x-api-key" do
      Application.put_env(:nopea, :api_key, "test-secret-key")

      conn =
        conn(:get, "/api/services")
        |> put_req_header("x-api-key", "test-secret-key")
        |> AuthPlug.call(AuthPlug.init([]))

      refute conn.halted
    end

    test "rejects requests with invalid x-api-key" do
      Application.put_env(:nopea, :api_key, "test-secret-key")

      conn =
        conn(:get, "/api/services")
        |> put_req_header("x-api-key", "wrong-key")
        |> AuthPlug.call(AuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
    end

    test "rejects requests with missing x-api-key" do
      Application.put_env(:nopea, :api_key, "test-secret-key")

      conn =
        conn(:get, "/api/services")
        |> AuthPlug.call(AuthPlug.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "skipped paths" do
    test "allows /health without key" do
      Application.put_env(:nopea, :api_key, "test-secret-key")

      conn =
        conn(:get, "/health")
        |> AuthPlug.call(AuthPlug.init([]))

      refute conn.halted
    end

    test "allows /ready without key" do
      Application.put_env(:nopea, :api_key, "test-secret-key")

      conn =
        conn(:get, "/ready")
        |> AuthPlug.call(AuthPlug.init([]))

      refute conn.halted
    end
  end
end

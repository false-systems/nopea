defmodule Nopea.API.AuthPlug do
  @moduledoc """
  Plug that authenticates API requests using an `x-api-key` header.

  ## Behaviour

  - If no API key is configured (nil), all requests pass through (dev mode).
  - If a key is configured, requests must include a matching `x-api-key` header.
  - `/health` and `/ready` paths are always allowed without authentication.
  - Returns 401 Unauthorized for missing or invalid keys.
  """

  @behaviour Plug

  import Plug.Conn

  @skip_paths ["/health", "/ready"]

  @impl true
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if skip_auth?(conn) do
      conn
    else
      case configured_key() do
        nil ->
          conn

        expected_key ->
          verify_key(conn, expected_key)
      end
    end
  end

  defp skip_auth?(conn) do
    conn.request_path in @skip_paths
  end

  defp configured_key do
    Application.get_env(:nopea, :api_key)
  end

  defp verify_key(conn, expected_key) do
    case get_req_header(conn, "x-api-key") do
      [^expected_key] ->
        conn

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end

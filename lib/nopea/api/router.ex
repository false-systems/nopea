defmodule Nopea.API.Router do
  @moduledoc """
  HTTP API router for Nopea.

  Provides health checks and deployment API for SYKLI integration.
  """

  use Plug.Router
  require Logger

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  def child_spec(opts) do
    port = Application.get_env(:nopea, :api_port, 4000)

    %{
      id: __MODULE__,
      start: {Plug.Cowboy, :http, [__MODULE__, opts, [port: port]]},
      type: :worker
    }
  end

  get "/health" do
    json(conn, 200, %{status: "ok"})
  end

  get "/ready" do
    json(conn, 200, %{status: "ready"})
  end

  post "/api/deploy" do
    handle_deploy(conn)
  end

  get "/api/status/:service" do
    case Nopea.Surface.status(service) do
      {:ok, state} -> json(conn, 200, state)
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, :unavailable} -> json(conn, 503, %{error: "unavailable"})
    end
  end

  get "/api/context/:service" do
    namespace = conn.params["namespace"] || "default"
    context = Nopea.Surface.context(service, namespace)
    json(conn, 200, context)
  end

  get "/api/history/:service" do
    case Nopea.Surface.history(service) do
      {:ok, data} -> json(conn, 200, data)
      {:error, :not_found} -> json(conn, 200, %{service: service, deployments: []})
      {:error, :unavailable} -> json(conn, 200, %{service: service, deployments: []})
    end
  end

  get "/api/explain/:service" do
    namespace = conn.params["namespace"] || "default"
    explanation = Nopea.Surface.explain(service, namespace)
    json(conn, 200, %{service: service, explanation: explanation})
  end

  get "/api/services" do
    services = Nopea.Surface.services()
    json(conn, 200, %{services: services, count: length(services)})
  end

  post "/api/promote/:deploy_id" do
    case Nopea.Surface.promote(deploy_id) do
      {:ok, rollout} -> json(conn, 200, Map.from_struct(rollout))
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/api/rollback/:deploy_id" do
    case Nopea.Surface.rollback(deploy_id) do
      {:ok, rollout} -> json(conn, 200, Map.from_struct(rollout))
      {:error, :not_found} -> json(conn, 404, %{error: "not_found"})
      {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
    end
  end

  match _ do
    json(conn, 404, %{error: "not_found"})
  end

  defp handle_deploy(conn) do
    case conn.body_params do
      %{"service" => service} = params ->
        spec = %Nopea.Deploy.Spec{
          service: service,
          namespace: params["namespace"] || "default",
          manifests: params["manifests"] || [],
          strategy: Nopea.Helpers.parse_strategy(params["strategy"])
        }

        result = Nopea.Deploy.deploy(spec)
        json(conn, 200, Nopea.Helpers.serialize_deploy_result(result))

      _ ->
        json(conn, 400, %{error: "service is required"})
    end
  rescue
    e ->
      Logger.error("Deploy request failed",
        error: Exception.message(e),
        stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
      )

      json(conn, 500, %{error: "Internal server error"})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

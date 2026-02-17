defmodule Nopea.API.Router do
  @moduledoc """
  HTTP API router for Nopea.

  Provides health checks and deployment API for SYKLI integration.
  """

  use Plug.Router

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

  get "/api/context/:service" do
    namespace = conn.params["namespace"] || "default"

    context =
      if Process.whereis(Nopea.Memory) do
        Nopea.Memory.get_deploy_context(service, namespace)
      else
        %{known: false}
      end

    json(conn, 200, context)
  end

  get "/api/history/:service" do
    history =
      if Nopea.Cache.available?() do
        case Nopea.Cache.get_service_state(service) do
          {:ok, state} -> %{service: service, state: state}
          {:error, :not_found} -> %{service: service, deployments: []}
        end
      else
        %{service: service, deployments: []}
      end

    json(conn, 200, history)
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
          strategy: parse_strategy(params["strategy"])
        }

        result = Nopea.Deploy.run(spec)

        json(conn, 200, %{
          deploy_id: result.deploy_id,
          status: result.status,
          service: result.service,
          namespace: result.namespace,
          strategy: result.strategy,
          duration_ms: result.duration_ms,
          manifest_count: result.manifest_count
        })

      _ ->
        json(conn, 400, %{error: "service is required"})
    end
  rescue
    e ->
      json(conn, 500, %{error: Exception.message(e)})
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp parse_strategy("canary"), do: :canary
  defp parse_strategy("blue_green"), do: :blue_green
  defp parse_strategy("direct"), do: :direct
  defp parse_strategy(_), do: nil
end

defmodule Nopea.MCP do
  @moduledoc """
  MCP (Model Context Protocol) server for Nopea.

  Exposes Nopea deployment capabilities as MCP tools over JSON-RPC.
  AI agents can use these tools to deploy, query context, and
  understand deployment history.

  ## Tools

  - `nopea_deploy` — Deploy manifests to a namespace
  - `nopea_context` — Get memory context for a service
  - `nopea_history` — Get deployment history
  - `nopea_explain` — Explain why a strategy was selected

  ## Protocol

  JSON-RPC 2.0 over stdin/stdout, newline-delimited.
  """

  require Logger

  @version "0.2.0"
  @protocol_version "2024-11-05"

  @tools [
    %{
      "name" => "nopea_deploy",
      "description" =>
        "Deploy manifests to Kubernetes. Returns deployment result with status, duration, and verification.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "service" => %{"type" => "string", "description" => "Service name"},
          "namespace" => %{
            "type" => "string",
            "description" => "Target namespace (default: 'default')"
          },
          "manifests" => %{"type" => "array", "description" => "List of K8s manifest objects"},
          "strategy" => %{
            "type" => "string",
            "description" => "Deploy strategy: direct, canary, blue_green"
          }
        },
        "required" => ["service"]
      }
    },
    %{
      "name" => "nopea_context",
      "description" =>
        "Get deployment memory context for a service. Returns failure patterns, recommendations, and dependency info.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "service" => %{"type" => "string", "description" => "Service name"},
          "namespace" => %{"type" => "string", "description" => "Namespace (default: 'default')"}
        },
        "required" => ["service"]
      }
    },
    %{
      "name" => "nopea_history",
      "description" => "Get deployment history for a service from the cache.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "service" => %{"type" => "string", "description" => "Service name"}
        },
        "required" => ["service"]
      }
    },
    %{
      "name" => "nopea_explain",
      "description" =>
        "Explain why a deployment strategy would be selected for a service based on memory context.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "service" => %{"type" => "string", "description" => "Service name"},
          "namespace" => %{"type" => "string", "description" => "Namespace (default: 'default')"}
        },
        "required" => ["service"]
      }
    }
  ]

  # Public API

  @spec handle_request(map()) :: {:ok, map()}
  def handle_request(%{"method" => "initialize", "id" => id}) do
    {:ok,
     success_response(id, %{
       "protocolVersion" => @protocol_version,
       "serverInfo" => %{"name" => "nopea", "version" => @version},
       "capabilities" => %{
         "tools" => %{"listChanged" => false}
       }
     })}
  end

  def handle_request(%{"method" => "tools/list", "id" => id}) do
    {:ok, success_response(id, %{"tools" => @tools})}
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => params}) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    case call_tool(tool_name, arguments) do
      {:ok, text} ->
        {:ok,
         success_response(id, %{
           "content" => [%{"type" => "text", "text" => text}]
         })}

      {:error, message} ->
        {:ok, error_response(id, -32_602, message)}
    end
  end

  def handle_request(%{"method" => "notifications/initialized"}) do
    {:ok, nil}
  end

  def handle_request(%{"id" => id}) do
    {:ok, error_response(id, -32_601, "Method not found")}
  end

  @spec encode(map()) :: binary()
  def encode(message) do
    Jason.encode!(message) <> "\n"
  end

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(line) do
    Jason.decode(String.trim(line))
  end

  @doc """
  Run the MCP server loop reading from stdin, writing to stdout.
  """
  @spec serve() :: :ok
  def serve do
    IO.stream(:stdio, :line)
    |> Stream.each(&handle_line/1)
    |> Stream.run()
  end

  defp handle_line(line) do
    case decode(line) do
      {:ok, request} -> dispatch(request)
      {:error, _} -> IO.write(encode(error_response(nil, -32_700, "Parse error")))
    end
  end

  defp dispatch(request) do
    case handle_request(request) do
      {:ok, nil} -> :ok
      {:ok, response} -> IO.write(encode(response))
    end
  end

  # Tool implementations

  defp call_tool("nopea_context", args) do
    service = args["service"]
    namespace = args["namespace"] || "default"

    if Process.whereis(Nopea.Memory) do
      context = Nopea.Memory.get_deploy_context(service, namespace)
      {:ok, Jason.encode!(context, pretty: true)}
    else
      {:ok, Jason.encode!(%{known: false, message: "Memory not available"})}
    end
  end

  defp call_tool("nopea_history", args) do
    service = args["service"]

    if Nopea.Cache.available?() do
      case Nopea.Cache.get_service_state(service) do
        {:ok, state} ->
          {:ok, Jason.encode!(%{service: service, state: state}, pretty: true)}

        {:error, :not_found} ->
          {:ok, Jason.encode!(%{service: service, deployments: [], message: "No history found"})}
      end
    else
      {:ok, Jason.encode!(%{service: service, deployments: [], message: "Cache not available"})}
    end
  end

  defp call_tool("nopea_deploy", args) do
    service = args["service"]

    if service == nil or service == "" do
      {:error, "service is required"}
    else
      spec = %Nopea.Deploy.Spec{
        service: service,
        namespace: args["namespace"] || "default",
        manifests: args["manifests"] || [],
        strategy: parse_strategy(args["strategy"])
      }

      result = Nopea.Deploy.run(spec)

      {:ok,
       Jason.encode!(
         %{
           deploy_id: result.deploy_id,
           status: result.status,
           service: result.service,
           namespace: result.namespace,
           strategy: result.strategy,
           duration_ms: result.duration_ms,
           manifest_count: result.manifest_count
         },
         pretty: true
       )}
    end
  rescue
    e -> {:error, "Deploy failed: #{Exception.message(e)}"}
  end

  defp call_tool("nopea_explain", args) do
    service = args["service"]
    namespace = args["namespace"] || "default"

    if Process.whereis(Nopea.Memory) do
      context = Nopea.Memory.get_deploy_context(service, namespace)
      {:ok, explain_strategy(service, namespace, context)}
    else
      {:ok, "Memory not available. Would use direct strategy by default."}
    end
  end

  defp call_tool(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  defp explain_strategy(service, namespace, context) do
    cond do
      not context.known ->
        "No deployment history for #{service}/#{namespace}. Would use direct strategy (default for unknown services)."

      Enum.any?(context.failure_patterns, fn p -> p.confidence > 0.15 end) ->
        patterns =
          Enum.map_join(context.failure_patterns, ", ", fn p ->
            "#{p.error} (confidence: #{Float.round(p.confidence, 2)})"
          end)

        "Would use canary strategy for #{service}/#{namespace}. " <>
          "Failure patterns detected: #{patterns}. " <>
          "Canary deploys gradually to reduce risk."

      true ->
        "Would use direct strategy for #{service}/#{namespace}. " <>
          "No significant failure patterns detected. Service is known and stable."
    end
  end

  defp parse_strategy("canary"), do: :canary
  defp parse_strategy("blue_green"), do: :blue_green
  defp parse_strategy("direct"), do: :direct
  defp parse_strategy(_), do: nil

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end

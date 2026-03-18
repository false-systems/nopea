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
  - `nopea_health` — Check health of active service agents
  - `nopea_explain` — Explain why a strategy was selected
  - `nopea_services` — List known services

  ## Protocol

  JSON-RPC 2.0 over stdin/stdout, newline-delimited.

  ## Lifecycle

  Supports `shutdown` request and `exit` notification per JSON-RPC/MCP spec.
  The `shutdown` request returns a null result and sets a shutdown flag.
  The `exit` notification halts the process: exit code 0 if shutdown was
  received, exit code 1 otherwise.
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
            "description" =>
              "Deploy strategy: direct (default), canary (requires Kulta), blue_green (requires Kulta)"
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
      "name" => "nopea_health",
      "description" =>
        "Check health of active service agents. Without args: lists all agents. With service: returns specific agent status.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "service" => %{
            "type" => "string",
            "description" => "Optional service name. Omit to list all agents."
          }
        },
        "required" => []
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
    },
    %{
      "name" => "nopea_services",
      "description" => "List all known services that have been deployed.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    },
    %{
      "name" => "nopea_promote",
      "description" => "Promote an active progressive rollout to completion.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "deploy_id" => %{"type" => "string", "description" => "Deploy ID of the active rollout"}
        },
        "required" => ["deploy_id"]
      }
    },
    %{
      "name" => "nopea_rollback",
      "description" => "Rollback an active progressive rollout.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "deploy_id" => %{"type" => "string", "description" => "Deploy ID of the active rollout"}
        },
        "required" => ["deploy_id"]
      }
    }
  ]

  @typedoc "Server state tracking lifecycle flags"
  @type state :: %{shutdown_received: boolean()}

  @doc "Returns initial MCP server state."
  @spec initial_state() :: state()
  def initial_state, do: %{shutdown_received: false}

  # Public API

  @doc """
  Handle a JSON-RPC request without state tracking.

  Returns `{:ok, response}` where response may be nil for notifications.
  """
  @spec handle_request(map()) :: {:ok, map() | nil}
  def handle_request(request) do
    {response, _state} = handle_request(request, initial_state())
    {:ok, response}
  end

  @doc """
  Handle a JSON-RPC request with state tracking.

  Returns `{response, new_state}` where response may be nil for notifications,
  or `:halt` to signal the server should stop (exit notification).
  """
  @spec handle_request(map(), state()) :: {map() | nil, state()} | :halt
  def handle_request(%{"method" => "initialize", "id" => id}, state) do
    {success_response(id, %{
       "protocolVersion" => @protocol_version,
       "serverInfo" => %{"name" => "nopea", "version" => @version},
       "capabilities" => %{
         "tools" => %{"listChanged" => false}
       }
     }), state}
  end

  def handle_request(%{"method" => "shutdown", "id" => id}, state) do
    {success_response(id, nil), %{state | shutdown_received: true}}
  end

  def handle_request(%{"method" => "exit"}, %{shutdown_received: true}) do
    :halt
  end

  def handle_request(%{"method" => "exit"}, %{shutdown_received: false}) do
    :halt
  end

  def handle_request(%{"method" => "tools/list", "id" => id}, state) do
    {success_response(id, %{"tools" => @tools}), state}
  end

  def handle_request(%{"method" => "tools/call", "id" => id, "params" => params}, state) do
    tool_name = params["name"]
    arguments = params["arguments"] || %{}

    case call_tool(tool_name, arguments) do
      {:ok, text} ->
        {success_response(id, %{
           "content" => [%{"type" => "text", "text" => text}]
         }), state}

      {:error, message} ->
        {error_response(id, -32_602, message), state}
    end
  end

  def handle_request(%{"method" => "notifications/initialized"}, state) do
    {nil, state}
  end

  def handle_request(%{"method" => "notifications/cancelled"} = request, state) do
    Logger.info("MCP notification cancelled",
      request_id: get_in(request, ["params", "id"]),
      reason: get_in(request, ["params", "reason"])
    )

    {nil, state}
  end

  def handle_request(%{"id" => id}, state) do
    {error_response(id, -32_601, "Method not found"), state}
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

  Tracks shutdown state across requests using `Enum.reduce_while/3`.
  On `exit` notification after `shutdown`, halts with exit code 0.
  On `exit` without prior `shutdown`, halts with exit code 1.
  """
  @spec serve() :: :ok
  def serve do
    _final_state =
      IO.stream(:stdio, :line)
      |> Enum.reduce_while(initial_state(), fn line, state ->
        case decode(line) do
          {:ok, request} ->
            dispatch(request, state)

          {:error, _} ->
            IO.write(encode(error_response(nil, -32_700, "Parse error")))
            {:cont, state}
        end
      end)

    :ok
  end

  defp dispatch(request, state) do
    case handle_request(request, state) do
      :halt ->
        exit_code = if state.shutdown_received, do: 0, else: 1
        System.halt(exit_code)

      {nil, new_state} ->
        {:cont, new_state}

      {response, new_state} ->
        IO.write(encode(response))
        {:cont, new_state}
    end
  end

  # Tool implementations — delegate to Surface

  defp call_tool("nopea_context", args) do
    service = args["service"]
    namespace = args["namespace"] || "default"
    context = Nopea.Surface.context(service, namespace)
    {:ok, Jason.encode!(context, pretty: true)}
  end

  defp call_tool("nopea_history", args) do
    service = args["service"]

    case Nopea.Surface.history(service) do
      {:ok, data} ->
        {:ok, Jason.encode!(data, pretty: true)}

      {:error, :not_found} ->
        {:ok, Jason.encode!(%{service: service, deployments: [], message: "No history found"})}

      {:error, :unavailable} ->
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
        strategy: Nopea.Helpers.parse_strategy(args["strategy"])
      }

      result = Nopea.Deploy.deploy(spec)
      {:ok, Jason.encode!(Nopea.Helpers.serialize_deploy_result(result), pretty: true)}
    end
  rescue
    e ->
      Logger.error("MCP deploy tool failed",
        service: args["service"],
        error: Exception.message(e),
        stacktrace: __STACKTRACE__ |> Exception.format_stacktrace()
      )

      {:error, "Deploy failed: #{Exception.message(e)}"}
  end

  defp call_tool("nopea_health", args) do
    case args["service"] do
      nil ->
        health = Nopea.Surface.health()
        {:ok, Jason.encode!(health, pretty: true)}

      service ->
        case Nopea.Surface.status(service) do
          {:ok, status} ->
            {:ok, Jason.encode!(status, pretty: true)}

          {:error, :not_found} ->
            {:ok, Jason.encode!(%{service: service, message: "No active agent"}, pretty: true)}

          {:error, :unavailable} ->
            {:ok, Jason.encode!(%{service: service, message: "No active agent"}, pretty: true)}
        end
    end
  end

  defp call_tool("nopea_explain", args) do
    service = args["service"]
    namespace = args["namespace"] || "default"
    {:ok, Nopea.Surface.explain(service, namespace)}
  end

  defp call_tool("nopea_services", _args) do
    services = Nopea.Surface.services()
    {:ok, Jason.encode!(%{services: services, count: length(services)}, pretty: true)}
  end

  defp call_tool("nopea_promote", args) do
    deploy_id = args["deploy_id"]

    case Nopea.Surface.promote(deploy_id) do
      {:ok, rollout} ->
        {:ok, Jason.encode!(Map.from_struct(rollout), pretty: true)}

      {:error, :not_found} ->
        {:error, "No active rollout for deploy '#{deploy_id}'"}

      {:error, reason} ->
        {:error, "Promote failed: #{inspect(reason)}"}
    end
  end

  defp call_tool("nopea_rollback", args) do
    deploy_id = args["deploy_id"]

    case Nopea.Surface.rollback(deploy_id) do
      {:ok, rollout} ->
        {:ok, Jason.encode!(Map.from_struct(rollout), pretty: true)}

      {:error, :not_found} ->
        {:error, "No active rollout for deploy '#{deploy_id}'"}

      {:error, reason} ->
        {:error, "Rollback failed: #{inspect(reason)}"}
    end
  end

  defp call_tool(name, _args) do
    {:error, "Unknown tool: #{name}"}
  end

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end

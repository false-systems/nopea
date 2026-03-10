defmodule Nopea.CLI do
  @moduledoc """
  Escript entry point for Nopea CLI.

  Commands:
  - deploy    Deploy manifests to a cluster
  - status    Show deployment status
  - context   Show memory context for a service
  - history   Show deployment history
  - explain   Explain strategy selection for a service
  - promote   Promote an active progressive rollout
  - rollback  Rollback an active progressive rollout
  - health    Show system health
  - services  List known services
  - memory    Show memory graph stats
  - serve     Start daemon mode (HTTP API)
  - mcp       Start MCP server (JSON-RPC over stdin/stdout)
  """

  require Logger

  def main(args) do
    {opts, args, _} =
      OptionParser.parse(args,
        switches: [
          json: :boolean,
          file: :string,
          service: :string,
          namespace: :string,
          strategy: :string
        ],
        aliases: [f: :file, s: :service, n: :namespace, j: :json]
      )

    dispatch(args, opts)
  end

  defp dispatch(["deploy" | _], opts), do: deploy(opts)
  defp dispatch(["status" | rest], opts), do: status(rest, opts)
  defp dispatch(["context" | rest], opts), do: context(rest, opts)
  defp dispatch(["history" | rest], opts), do: history(rest, opts)
  defp dispatch(["explain" | rest], opts), do: explain(rest, opts)
  defp dispatch(["health" | _], opts), do: health(opts)
  defp dispatch(["services" | _], opts), do: services(opts)
  defp dispatch(["memory" | _], opts), do: memory(opts)
  defp dispatch(["promote" | rest], opts), do: promote(rest, opts)
  defp dispatch(["rollback" | rest], opts), do: do_rollback(rest, opts)
  defp dispatch(["serve" | _], opts), do: serve(opts)
  defp dispatch(["mcp" | _], _opts), do: mcp()
  defp dispatch(_, _opts), do: usage()

  defp deploy(opts) do
    path = Keyword.get(opts, :file) || "."
    service = Keyword.get(opts, :service) || Path.basename(path)
    namespace = Keyword.get(opts, :namespace, "default")
    strategy = Nopea.Helpers.parse_strategy(Keyword.get(opts, :strategy))

    case Nopea.Deploy.Spec.from_path(path, service, namespace, strategy: strategy) do
      {:ok, spec} ->
        result = Nopea.Deploy.deploy(spec)
        output(result, opts)

      {:error, reason} ->
        error("Failed to load manifests: #{inspect(reason)}")
    end
  end

  defp status(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)

    unless service do
      error("Usage: nopea status <service>")
    end

    case Nopea.Surface.status(service) do
      {:ok, state} -> output(state, opts)
      {:error, :not_found} -> error("Service '#{service}' not found")
      {:error, :unavailable} -> error("No status backend available")
    end
  end

  defp context(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)
    namespace = Keyword.get(opts, :namespace, "default")

    unless service do
      error("Usage: nopea context <service>")
    end

    ctx = Nopea.Surface.context(service, namespace)
    output(ctx, opts)
  end

  defp history(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)

    unless service do
      error("Usage: nopea history <service>")
    end

    case Nopea.Surface.history(service) do
      {:ok, data} -> output(data, opts)
      {:error, :not_found} -> error("No history found for '#{service}'")
      {:error, :unavailable} -> error("Cache not available")
    end
  end

  defp explain(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)
    namespace = Keyword.get(opts, :namespace, "default")

    unless service do
      error("Usage: nopea explain <service>")
    end

    result = Nopea.Surface.explain(service, namespace)
    output(result, opts)
  end

  defp health(opts) do
    result = Nopea.Surface.health()
    output(result, opts)
  end

  defp services(opts) do
    result = Nopea.Surface.services()
    output(result, opts)
  end

  defp promote(args, opts) do
    deploy_id = List.first(args)

    unless deploy_id do
      error("Usage: nopea promote <deploy_id>")
    end

    case Nopea.Surface.promote(deploy_id) do
      {:ok, rollout} -> output(rollout, opts)
      {:error, :not_found} -> error("No active rollout for deploy '#{deploy_id}'")
      {:error, reason} -> error("Promote failed: #{inspect(reason)}")
    end
  end

  defp do_rollback(args, opts) do
    deploy_id = List.first(args)

    unless deploy_id do
      error("Usage: nopea rollback <deploy_id>")
    end

    case Nopea.Surface.rollback(deploy_id) do
      {:ok, rollout} -> output(rollout, opts)
      {:error, :not_found} -> error("No active rollout for deploy '#{deploy_id}'")
      {:error, reason} -> error("Rollback failed: #{inspect(reason)}")
    end
  end

  defp memory(opts) do
    result = Nopea.Surface.health()
    output(result.memory, opts)
  end

  defp serve(_opts) do
    Logger.info("Starting Nopea daemon...")
    Application.put_env(:nopea, :enable_router, true)

    case Application.ensure_all_started(:nopea) do
      {:ok, _apps} ->
        port = Application.get_env(:nopea, :api_port, 4000)
        Logger.info("Nopea API listening on port #{port}")
        Process.sleep(:infinity)

      {:error, reason} ->
        Logger.error("Failed to start Nopea: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp mcp do
    Nopea.MCP.serve()
  end

  defp output(data, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(data, pretty: true))
    else
      data |> inspect(pretty: true) |> IO.puts()
    end
  end

  defp error(message) do
    IO.puts(:stderr, "Error: #{message}")
    System.halt(1)
  end

  defp usage do
    IO.puts("""
    Nopea — AI-native deployments with memory

    Usage:
      nopea deploy -f <path> -s <service> -n <namespace>
      nopea status <service>
      nopea context <service> [--json]
      nopea history <service> [--json]
      nopea explain <service> [--json]
      nopea promote <deploy_id> [--json]
      nopea rollback <deploy_id> [--json]
      nopea health [--json]
      nopea services [--json]
      nopea memory [--json]
      nopea serve
      nopea mcp
    """)
  end
end

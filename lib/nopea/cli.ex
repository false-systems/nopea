defmodule Nopea.CLI do
  @moduledoc """
  Escript entry point for Nopea CLI.

  Commands:
  - deploy   Deploy manifests to a cluster
  - status   Show deployment status
  - context  Show memory context for a service
  - history  Show deployment history
  - rollback Roll back a deployment
  - memory   Show memory graph stats
  - serve    Start daemon mode (HTTP API)
  """

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

    case args do
      ["deploy" | _] -> deploy(opts)
      ["status" | rest] -> status(rest, opts)
      ["context" | rest] -> context(rest, opts)
      ["history" | rest] -> history(rest, opts)
      ["memory" | _] -> memory(opts)
      ["serve" | _] -> serve(opts)
      _ -> usage()
    end
  end

  defp deploy(opts) do
    path = Keyword.get(opts, :file) || "."
    service = Keyword.get(opts, :service) || Path.basename(path)
    namespace = Keyword.get(opts, :namespace, "default")
    strategy = Nopea.Helpers.parse_strategy(Keyword.get(opts, :strategy))

    case Nopea.Deploy.Spec.from_path(path, service, namespace, strategy: strategy) do
      {:ok, spec} ->
        result = Nopea.Deploy.run(spec)
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

    case Nopea.Cache.get_service_state(service) do
      {:ok, state} -> output(state, opts)
      {:error, :not_found} -> error("Service '#{service}' not found")
    end
  end

  defp context(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)
    namespace = Keyword.get(opts, :namespace, "default")

    unless service do
      error("Usage: nopea context <service>")
    end

    ctx = Nopea.Memory.get_deploy_context(service, namespace)
    output(ctx, opts)
  end

  defp history(args, opts) do
    service = List.first(args) || Keyword.get(opts, :service)

    unless service do
      error("Usage: nopea history <service>")
    end

    deploys = Nopea.Cache.list_deployments(service)
    output(deploys, opts)
  end

  defp memory(opts) do
    stats = %{
      nodes: Nopea.Memory.node_count(),
      relationships: Nopea.Memory.relationship_count()
    }

    output(stats, opts)
  end

  defp serve(_opts) do
    IO.puts("Starting Nopea daemon...")

    case Supervisor.start_child(Nopea.AppSupervisor, Nopea.API.Router) do
      {:ok, _pid} ->
        port = Application.get_env(:nopea, :api_port, 4000)
        IO.puts("Nopea API listening on port #{port}")

      {:error, {:already_started, _pid}} ->
        IO.puts("Nopea API already running")

      {:error, reason} ->
        IO.puts(:stderr, "Failed to start API: #{inspect(reason)}")
    end

    Process.sleep(:infinity)
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
      nopea memory [--json]
      nopea serve
    """)
  end
end

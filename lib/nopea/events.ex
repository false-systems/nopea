defmodule Nopea.Events do
  @moduledoc """
  CDEvents emission for deployment observability.

  Implements CDEvents v0.5.0 for continuous delivery events.
  Events are CloudEvents-compatible and emitted via HTTP.

  ## Supported Event Types

  - `:deploy_started` - Deployment initiated
  - `:deploy_completed` - Deployment succeeded
  - `:deploy_failed` - Deployment failed
  - `:deploy_rolledback` - Deployment rolled back
  - `:service_deployed` - Service first deployed
  - `:service_upgraded` - Service updated
  """

  @specversion "1.0"

  @type event_type ::
          :deploy_started
          | :deploy_completed
          | :deploy_failed
          | :deploy_rolledback
          | :service_deployed
          | :service_upgraded

  @type subject :: %{
          id: String.t(),
          content: map()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          source: String.t(),
          specversion: String.t(),
          timestamp: DateTime.t(),
          subject: subject()
        }

  defstruct [:id, :type, :source, :specversion, :timestamp, :subject]

  @event_type_map %{
    deploy_started: "dev.cdevents.deployment.started.0.1.0",
    deploy_completed: "dev.cdevents.deployment.completed.0.1.0",
    deploy_failed: "dev.cdevents.deployment.failed.0.1.0",
    deploy_rolledback: "dev.cdevents.deployment.rolledback.0.1.0",
    service_deployed: "dev.cdevents.service.deployed.0.3.0",
    service_upgraded: "dev.cdevents.service.upgraded.0.3.0"
  }

  @spec new(map()) :: t()
  def new(%{type: type, source: source, subject_id: subject_id, content: content}) do
    %__MODULE__{
      id: generate_id(),
      type: Map.fetch!(@event_type_map, type),
      source: source,
      specversion: @specversion,
      timestamp: DateTime.utc_now(),
      subject: %{
        id: subject_id,
        content: content
      }
    }
  end

  # Builder Functions

  @spec deploy_started(String.t(), map()) :: t()
  def deploy_started(service, opts) do
    new(%{
      type: :deploy_started,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        deploy_id: opts[:deploy_id],
        strategy: opts[:strategy],
        namespace: opts[:namespace],
        manifest_count: opts[:manifest_count]
      }
    })
  end

  @spec deploy_completed(String.t(), map()) :: t()
  def deploy_completed(service, opts) do
    new(%{
      type: :deploy_completed,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        deploy_id: opts[:deploy_id],
        strategy: opts[:strategy],
        namespace: opts[:namespace],
        duration_ms: opts[:duration_ms],
        verified: opts[:verified]
      }
    })
  end

  @spec deploy_failed(String.t(), map()) :: t()
  def deploy_failed(service, opts) do
    new(%{
      type: :deploy_failed,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        deploy_id: opts[:deploy_id],
        strategy: opts[:strategy],
        namespace: opts[:namespace],
        error: normalize_error(opts[:error]),
        duration_ms: opts[:duration_ms]
      }
    })
  end

  @spec deploy_rolledback(String.t(), map()) :: t()
  def deploy_rolledback(service, opts) do
    new(%{
      type: :deploy_rolledback,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        deploy_id: opts[:deploy_id],
        namespace: opts[:namespace],
        reason: opts[:reason]
      }
    })
  end

  @spec service_deployed(String.t(), map()) :: t()
  def service_deployed(service, opts) do
    new(%{
      type: :service_deployed,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        environment: %{id: Map.get(opts, :namespace, "default"), source: "/nopea"},
        artifactId: opts[:commit] && "pkg:deploy/#{service}@#{opts[:commit]}",
        manifest_count: opts[:manifest_count],
        duration_ms: opts[:duration_ms]
      }
    })
  end

  @spec service_upgraded(String.t(), map()) :: t()
  def service_upgraded(service, opts) do
    new(%{
      type: :service_upgraded,
      source: "/nopea/deploy/#{service}",
      subject_id: service,
      content: %{
        environment: %{id: Map.get(opts, :namespace, "default"), source: "/nopea"},
        manifest_count: opts[:manifest_count],
        duration_ms: opts[:duration_ms]
      }
    })
  end

  @spec to_json(t()) :: {:ok, String.t()} | {:error, term()}
  def to_json(%__MODULE__{} = event) do
    json_map = %{
      id: event.id,
      type: event.type,
      source: event.source,
      specversion: event.specversion,
      timestamp: DateTime.to_iso8601(event.timestamp),
      subject: event.subject
    }

    Jason.encode(json_map)
  end

  defp generate_id do
    case Process.whereis(Nopea.ULID) do
      nil -> Nopea.ULID.generate_random()
      _pid -> Nopea.ULID.generate()
    end
  end

  defp normalize_error({type, message}) when is_atom(type) and is_binary(message) do
    %{type: Atom.to_string(type), message: message}
  end

  defp normalize_error({type, message}) when is_atom(type) do
    %{type: Atom.to_string(type), message: inspect(message)}
  end

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(nil), do: nil
  defp normalize_error(error), do: inspect(error)
end

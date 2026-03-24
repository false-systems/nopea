defmodule Nopea.Oracle do
  @moduledoc """
  Oracle test helpers for Nopea blackbox testing.

  Connects to a live Nopea instance via HTTP API and MCP protocol.
  All helpers read configuration from application env with env var overrides.
  """

  # --- Configuration ---

  def base_url, do: Application.get_env(:nopea_oracle, :base_url, "http://localhost:4000")
  def api_key, do: Application.get_env(:nopea_oracle, :api_key)
  def settle_ms, do: Application.get_env(:nopea_oracle, :settle_ms, 500)
  def mcp_binary, do: Application.get_env(:nopea_oracle, :mcp_binary, "../../nopea")

  # --- HTTP Client ---

  def http_get(path, opts \\ []) do
    Req.get!(url(path), headers: auth_headers(opts), receive_timeout: timeout(opts))
  end

  def http_post(path, body, opts \\ []) do
    Req.post!(url(path), json: body, headers: auth_headers(opts), receive_timeout: timeout(opts))
  end

  def http_get_raw(path, opts \\ []) do
    Req.get(url(path), headers: auth_headers(opts), receive_timeout: timeout(opts))
  end

  def http_post_raw(path, body, opts \\ []) do
    Req.post(url(path), json: body, headers: auth_headers(opts), receive_timeout: timeout(opts))
  end

  def http_request(method, path, opts \\ []) do
    Req.request!(method: method, url: url(path), headers: auth_headers(opts), receive_timeout: timeout(opts))
  end

  # Raw request with no JSON content-type (for malformed body tests)
  def http_raw_post(path, raw_body, opts \\ []) do
    Req.post!(url(path),
      body: raw_body,
      headers: [{"content-type", "application/json"} | auth_headers(opts)],
      receive_timeout: timeout(opts)
    )
  end

  # --- MCP Client ---

  def mcp_request(port, request) do
    line = Jason.encode!(request) <> "\n"
    Port.command(port, line)
    receive_mcp_response(port, 5_000)
  end

  def start_mcp do
    binary = Path.expand(mcp_binary())

    Port.open({:spawn_executable, binary}, [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      args: ["mcp"]
    ])
  end

  def stop_mcp(port) do
    Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp receive_mcp_response(port, timeout) do
    receive do
      {^port, {:data, data}} ->
        case Jason.decode(String.trim(data)) do
          {:ok, response} -> {:ok, response}
          {:error, _} -> receive_mcp_response(port, timeout)
        end

      {^port, {:exit_status, code}} ->
        {:exit, code}
    after
      timeout -> {:error, :timeout}
    end
  end

  # --- Factories ---

  def sample_deployment(name, namespace \\ "default") do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => %{"app" => name}
      },
      "spec" => %{
        "replicas" => 1,
        "selector" => %{"matchLabels" => %{"app" => name}},
        "template" => %{
          "metadata" => %{"labels" => %{"app" => name}},
          "spec" => %{
            "containers" => [
              %{
                "name" => name,
                "image" => "nginx:1.25",
                "ports" => [%{"containerPort" => 80}]
              }
            ]
          }
        }
      }
    }
  end

  def sample_service(name, namespace \\ "default") do
    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace
      },
      "spec" => %{
        "selector" => %{"app" => name},
        "ports" => [%{"port" => 80, "targetPort" => 80}]
      }
    }
  end

  def sample_configmap(name, namespace \\ "default", data \\ %{"key" => "value"}) do
    %{
      "apiVersion" => "v1",
      "kind" => "ConfigMap",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace
      },
      "data" => data
    }
  end

  # Intentionally invalid manifests
  def manifest_no_api_version do
    %{"kind" => "Deployment", "metadata" => %{"name" => "bad"}}
  end

  def manifest_no_kind do
    %{"apiVersion" => "v1", "metadata" => %{"name" => "bad"}}
  end

  def manifest_no_metadata do
    %{"apiVersion" => "v1", "kind" => "ConfigMap"}
  end

  def manifest_no_name do
    %{"apiVersion" => "v1", "kind" => "ConfigMap", "metadata" => %{}}
  end

  # --- Settlement ---

  def settle, do: Process.sleep(settle_ms())
  def settle(ms), do: Process.sleep(ms)

  # --- Assertions ---

  def assert_json_shape(body, required_keys) when is_map(body) do
    missing = Enum.reject(required_keys, &Map.has_key?(body, &1))

    if missing != [] do
      raise ExUnit.AssertionError,
        message: "Missing keys in response: #{inspect(missing)}\nGot: #{inspect(Map.keys(body))}"
    end
  end

  # --- Internal ---

  defp url(path), do: base_url() <> path

  defp auth_headers(opts) do
    key = Keyword.get(opts, :api_key, api_key())
    if key, do: [{"x-api-key", key}], else: []
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout, 15_000)
end

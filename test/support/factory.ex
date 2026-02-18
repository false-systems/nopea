defmodule Nopea.Test.Factory do
  @moduledoc """
  Test factories for building common test data.
  """

  alias Nopea.Deploy.Spec

  @doc "Builds a deploy spec with sensible defaults."
  def build_spec(overrides \\ %{}) do
    defaults = %{
      service: "test-svc",
      namespace: "default",
      manifests: [],
      strategy: :direct
    }

    attrs = Map.merge(defaults, Map.new(overrides))

    %Spec{
      service: attrs.service,
      namespace: attrs.namespace,
      manifests: attrs.manifests,
      strategy: attrs.strategy
    }
  end

  @doc "Builds a deploy result map for use with Memory.record_deploy/1."
  def build_result(overrides \\ %{}) do
    defaults = %{
      service: "test-svc",
      namespace: "default",
      status: :completed,
      error: nil,
      duration_ms: 150,
      concurrent_deploys: []
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc "Returns a sample Kubernetes Deployment manifest."
  def sample_deployment_manifest(name, namespace \\ "default") do
    %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace
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
                "image" => "#{name}:latest",
                "ports" => [%{"containerPort" => 8080}]
              }
            ]
          }
        }
      }
    }
  end

  @doc "Returns a sample Kubernetes Service manifest."
  def sample_service_manifest(name, namespace \\ "default") do
    %{
      "apiVersion" => "v1",
      "kind" => "Service",
      "metadata" => %{
        "name" => name,
        "namespace" => namespace
      },
      "spec" => %{
        "selector" => %{"app" => name},
        "ports" => [%{"port" => 80, "targetPort" => 8080}],
        "type" => "ClusterIP"
      }
    }
  end

  @doc "Returns a sample Kubernetes ConfigMap manifest."
  def sample_configmap_manifest(name, namespace \\ "default", data \\ %{}) do
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
end

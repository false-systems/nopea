defmodule Nopea.DriftVerifyTest do
  use ExUnit.Case

  alias Nopea.Drift
  alias Nopea.Test.Factory

  setup do
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "verify_manifest/3" do
    test "returns :new_resource when no cache entry and K8s resource missing" do
      manifest = Factory.sample_deployment_manifest("new-svc")

      result =
        Drift.verify_manifest("new-svc", manifest,
          k8s_module: Nopea.DriftVerifyTest.StubK8sNotFound,
          cache_module: Nopea.Cache
        )

      assert result == :new_resource
    end

    test "returns :no_drift when cached matches live" do
      manifest = Factory.sample_deployment_manifest("stable-svc")
      resource_key = Nopea.Applier.resource_key(manifest)

      # Store in cache as "last applied"
      Nopea.Cache.put_last_applied("stable-svc", resource_key, manifest)

      # K8s returns same manifest (with some extra fields)
      live_manifest =
        manifest
        |> put_in(["metadata", "resourceVersion"], "12345")
        |> put_in(["metadata", "uid"], "abc-def")

      result =
        Drift.verify_manifest("stable-svc", manifest,
          k8s_module: stub_k8s_returning(live_manifest),
          cache_module: Nopea.Cache
        )

      assert result == :no_drift
    end

    test "detects :manual_drift when live differs from cached" do
      manifest = Factory.sample_deployment_manifest("drifted-svc")
      resource_key = Nopea.Applier.resource_key(manifest)

      # Store original in cache
      Nopea.Cache.put_last_applied("drifted-svc", resource_key, manifest)

      # K8s returns modified manifest (someone manually changed the image)
      drifted =
        manifest
        |> put_in(
          ["spec", "template", "spec", "containers", Access.at(0), "image"],
          "drifted-svc:hacked"
        )
        |> put_in(["metadata", "resourceVersion"], "99999")

      result =
        Drift.verify_manifest("drifted-svc", manifest,
          k8s_module: stub_k8s_returning(drifted),
          cache_module: Nopea.Cache
        )

      assert {:manual_drift, %{expected: _, actual: _}} = result
    end

    test "returns :needs_apply when no cache but resource exists in K8s" do
      manifest = Factory.sample_deployment_manifest("existing-svc")

      result =
        Drift.verify_manifest("existing-svc", manifest,
          k8s_module: stub_k8s_returning(manifest),
          cache_module: Nopea.Cache
        )

      assert result == :needs_apply
    end
  end

  describe "three_way_diff/3" do
    test "returns :no_drift when all three states match" do
      manifest = Factory.sample_deployment_manifest("same")
      assert Drift.three_way_diff(manifest, manifest, manifest) == :no_drift
    end

    test "detects git_change when desired differs from last_applied" do
      last = Factory.sample_deployment_manifest("svc")
      # Use container image change (not replicas, which is stripped by normalize)
      desired =
        put_in(last, ["spec", "template", "spec", "containers", Access.at(0), "image"], "svc:v2")

      result = Drift.three_way_diff(last, desired, last)
      assert {:git_change, %{from: _, to: _}} = result
    end

    test "detects conflict when both desired and live differ" do
      last = Factory.sample_deployment_manifest("svc")

      desired =
        put_in(last, ["spec", "template", "spec", "containers", Access.at(0), "image"], "svc:v2")

      live =
        put_in(last, ["spec", "template", "spec", "containers", Access.at(0), "image"], "svc:v3")

      result = Drift.three_way_diff(last, desired, live)
      assert {:conflict, %{last: _, desired: _, live: _}} = result
    end
  end

  describe "normalize/1" do
    test "strips K8s managed metadata fields" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{
          "name" => "test",
          "resourceVersion" => "12345",
          "uid" => "abc-def",
          "creationTimestamp" => "2024-01-01T00:00:00Z"
        },
        "data" => %{"key" => "value"}
      }

      normalized = Drift.normalize(manifest)
      metadata = normalized["metadata"]

      assert metadata["name"] == "test"
      refute Map.has_key?(metadata, "resourceVersion")
      refute Map.has_key?(metadata, "uid")
      refute Map.has_key?(metadata, "creationTimestamp")
    end

    test "strips status field" do
      manifest = %{
        "apiVersion" => "v1",
        "kind" => "ConfigMap",
        "metadata" => %{"name" => "test"},
        "status" => %{"phase" => "Active"}
      }

      normalized = Drift.normalize(manifest)
      refute Map.has_key?(normalized, "status")
    end
  end

  # Helper to create a K8s stub that returns a specific resource
  defp stub_k8s_returning(manifest) do
    module_name = :"Elixir.Nopea.DriftVerifyTest.DynamicStub#{System.unique_integer([:positive])}"

    Module.create(
      module_name,
      quote do
        def get_resource(_api_version, _kind, _name, _namespace) do
          {:ok, unquote(Macro.escape(manifest))}
        end

        def conn, do: {:ok, %{}}
        def apply_manifests(_, _), do: {:ok, []}
        def apply_manifest(_, _), do: {:ok, %{}}
        def delete_resource(_, _, _, _), do: :ok
      end,
      Macro.Env.location(__ENV__)
    )

    module_name
  end

  # Stub module that always returns not found
  defmodule StubK8sNotFound do
    def get_resource(_api_version, _kind, _name, _namespace) do
      {:error, :not_found}
    end

    def conn, do: {:ok, %{}}
    def apply_manifests(_, _), do: {:ok, []}
    def apply_manifest(_, _), do: {:ok, %{}}
    def delete_resource(_, _, _, _), do: :ok
  end
end

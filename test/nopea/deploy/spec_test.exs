defmodule Nopea.Deploy.SpecTest do
  use ExUnit.Case, async: true

  alias Nopea.Deploy.Spec

  describe "from_map/1" do
    test "creates spec from map with all fields" do
      spec =
        Spec.from_map(%{
          service: "auth-service",
          namespace: "production",
          manifests: [%{"kind" => "Deployment"}],
          strategy: :canary,
          manifest_path: "/tmp/manifests",
          timeout_ms: 60_000
        })

      assert spec.service == "auth-service"
      assert spec.namespace == "production"
      assert spec.manifests == [%{"kind" => "Deployment"}]
      assert spec.strategy == :canary
      assert spec.manifest_path == "/tmp/manifests"
      assert spec.timeout_ms == 60_000
    end

    test "uses defaults for optional fields" do
      spec = Spec.from_map(%{service: "my-svc"})

      assert spec.namespace == "default"
      assert spec.manifests == []
      assert spec.strategy == nil
      assert spec.manifest_path == nil
      assert spec.timeout_ms == 120_000
    end

    test "raises on missing service" do
      assert_raise KeyError, fn ->
        Spec.from_map(%{namespace: "default"})
      end
    end
  end

  describe "from_path/4" do
    test "loads manifests from YAML files" do
      # Create temp dir with a manifest
      dir = Path.join(System.tmp_dir!(), "nopea_spec_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      yaml = """
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: test-config
      data:
        key: value
      """

      File.write!(Path.join(dir, "config.yaml"), yaml)

      assert {:ok, spec} = Spec.from_path(dir, "test-svc", "default")
      assert spec.service == "test-svc"
      assert spec.namespace == "default"
      assert length(spec.manifests) == 1
      assert spec.manifest_path == dir

      File.rm_rf!(dir)
    end

    test "returns ok with empty manifests for nonexistent path" do
      # read_manifests_from_path returns {:ok, []} when no YAML files found
      assert {:ok, spec} = Spec.from_path("/nonexistent/path", "svc", "ns")
      assert spec.manifests == []
    end

    test "passes strategy option through" do
      dir = Path.join(System.tmp_dir!(), "nopea_spec_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "test.yaml"),
        "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: x\n"
      )

      assert {:ok, spec} = Spec.from_path(dir, "svc", "ns", strategy: :blue_green)
      assert spec.strategy == :blue_green

      File.rm_rf!(dir)
    end
  end
end

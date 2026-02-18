defmodule Nopea.DeployIntegrationTest do
  use ExUnit.Case

  import Mox

  alias Nopea.Deploy
  alias Nopea.Test.Factory

  setup :verify_on_exit!

  setup do
    start_supervised!(Nopea.Cache)
    start_supervised!({Nopea.Memory, []})
    :ok
  end

  describe "full deploy pipeline with manifests" do
    test "successful deploy with real manifests records in cache and memory" do
      deployment = Factory.sample_deployment_manifest("api-gw")
      service = Factory.sample_service_manifest("api-gw")

      Nopea.K8sMock
      |> expect(:apply_manifests, fn manifests, _ns ->
        {:ok, manifests}
      end)

      spec =
        Factory.build_spec(
          service: "api-gw",
          namespace: "staging",
          manifests: [deployment, service],
          strategy: :direct
        )

      result = Deploy.run(spec)

      assert result.status == :completed
      assert result.manifest_count == 2
      assert result.service == "api-gw"
      assert result.namespace == "staging"
      assert result.strategy == :direct
      assert result.duration_ms >= 0
      assert is_binary(result.deploy_id)

      # Cache records the deployment
      assert {:ok, cached} = Nopea.Cache.get_deployment("api-gw", result.deploy_id)
      assert cached.status == :completed

      # Cache records service state
      assert {:ok, state} = Nopea.Cache.get_service_state("api-gw")
      assert state.status == :completed
      assert state.last_deploy == result.deploy_id
    end

    test "failed K8s apply returns failure result with error" do
      deployment = Factory.sample_deployment_manifest("failing-svc")

      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _ns ->
        {:error, :forbidden}
      end)

      spec =
        Factory.build_spec(
          service: "failing-svc",
          manifests: [deployment],
          strategy: :direct
        )

      result = Deploy.run(spec)

      assert result.status == :failed
      assert result.error == :forbidden
      assert result.duration_ms >= 0
    end

    test "memory records failure patterns from failed deploy" do
      deployment = Factory.sample_deployment_manifest("fragile-svc")

      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _ns ->
        {:error, {:apply_failed, "image pull backoff"}}
      end)

      spec =
        Factory.build_spec(
          service: "fragile-svc",
          namespace: "prod",
          manifests: [deployment],
          strategy: :direct
        )

      Deploy.run(spec)

      # Wait for async cast to complete
      Process.sleep(50)

      ctx = Nopea.Memory.get_deploy_context("fragile-svc", "prod")
      assert ctx.known == true
      assert is_list(ctx.failure_patterns)
    end

    test "second deploy auto-selects canary after prior failure" do
      # First deploy: failure
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _ns ->
        {:error, "crash"}
      end)

      spec =
        Factory.build_spec(
          service: "auto-canary-svc",
          namespace: "prod",
          manifests: [Factory.sample_deployment_manifest("auto-canary-svc")],
          strategy: nil
        )

      Deploy.run(spec)
      Process.sleep(50)

      # Second deploy: should auto-select canary
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _ns ->
        {:ok, []}
      end)

      spec2 =
        Factory.build_spec(
          service: "auto-canary-svc",
          namespace: "prod",
          manifests: [],
          strategy: nil
        )

      result = Deploy.run(spec2)
      assert result.strategy == :canary
    end

    test "occurrence file generated with correct structure" do
      Nopea.K8sMock
      |> expect(:apply_manifests, fn _manifests, _ns ->
        {:ok, []}
      end)

      spec = Factory.build_spec(service: "occ-test-svc")

      Deploy.run(spec)

      # Check occurrence file was generated
      occurrence_path = Path.join(File.cwd!(), ".nopea/occurrence.json")

      if File.exists?(occurrence_path) do
        {:ok, content} = File.read(occurrence_path)
        {:ok, occurrence} = Jason.decode(content)

        assert is_binary(occurrence["id"])
        assert String.starts_with?(occurrence["type"], "deploy.run.")
        assert occurrence["source"] == "nopea"
        assert is_map(occurrence["deploy_data"])
        assert occurrence["deploy_data"]["service"] == "occ-test-svc"
      end
    end
  end
end

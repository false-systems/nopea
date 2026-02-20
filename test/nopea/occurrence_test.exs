defmodule Nopea.OccurrenceTest do
  use ExUnit.Case, async: true

  alias Nopea.Occurrence

  @successful_result %{
    service: "auth-service",
    namespace: "production",
    strategy: :direct,
    status: :completed,
    deploy_id: "01ABC",
    manifests_applied: 3,
    duration_ms: 1500,
    verified: true,
    error: nil
  }

  @failed_result %{
    service: "payment-svc",
    namespace: "production",
    strategy: :canary,
    status: :failed,
    deploy_id: "01DEF",
    manifests_applied: 0,
    duration_ms: 30_000,
    verified: false,
    error: {:timeout, "connection refused to api-server"}
  }

  describe "build/1 for successful deploys" do
    test "produces valid FALSE Protocol envelope" do
      occurrence = Occurrence.build(@successful_result)

      assert occurrence["version"] == "1.0"
      assert occurrence["source"] == "nopea"
      assert occurrence["type"] == "deploy.run.completed"
      assert occurrence["severity"] == "info"
      assert occurrence["outcome"] == "completed"
      assert is_binary(occurrence["id"])
      assert is_binary(occurrence["timestamp"])
    end

    test "has no error block on success" do
      occurrence = Occurrence.build(@successful_result)
      refute Map.has_key?(occurrence, "error")
    end

    test "has no reasoning block on success" do
      occurrence = Occurrence.build(@successful_result)
      refute Map.has_key?(occurrence, "reasoning")
    end

    test "has history block" do
      occurrence = Occurrence.build(@successful_result)

      assert history = occurrence["history"]
      assert is_list(history["steps"])
      assert history["duration_ms"] == 1500
    end

    test "has deploy_data block" do
      occurrence = Occurrence.build(@successful_result)

      assert data = occurrence["deploy_data"]
      assert data["service"] == "auth-service"
      assert data["namespace"] == "production"
      assert data["strategy"] == "direct"
      assert data["manifests_applied"] == 3
      assert data["verified"] == true
    end
  end

  describe "build/1 for failed deploys" do
    test "produces failed envelope" do
      occurrence = Occurrence.build(@failed_result)

      assert occurrence["type"] == "deploy.run.failed"
      assert occurrence["severity"] == "error"
      assert occurrence["outcome"] == "failed"
    end

    test "has error block with structured details" do
      occurrence = Occurrence.build(@failed_result)

      assert error = occurrence["error"]
      assert error["code"] == "timeout"
      assert is_binary(error["what_failed"])
      assert String.contains?(error["what_failed"], "payment-svc")
    end

    test "error block has why_it_matters for canary" do
      occurrence = Occurrence.build(@failed_result)

      assert error = occurrence["error"]
      assert is_binary(error["why_it_matters"])
    end
  end

  describe "build/2 with memory context" do
    test "includes reasoning block with memory context" do
      memory_context = %{
        known: true,
        failure_patterns: [
          %{
            error: "timeout",
            confidence: 0.85,
            observations: 4,
            evidence: ["deploy failed: timeout at 2024-01-10"]
          }
        ],
        dependencies: [
          %{target: "namespace:production", weight: 0.9, observations: 12}
        ],
        recommendations: [
          "High failure rate (0.85) for timeout — seen 4 times. Consider canary deployment."
        ]
      }

      occurrence = Occurrence.build(@failed_result, memory_context)

      assert reasoning = occurrence["reasoning"]
      assert is_binary(reasoning["summary"])
      assert reasoning["confidence"] > 0
      assert is_list(reasoning["memory_context"])
      assert reasoning["memory_context"] != []
    end

    test "reasoning includes recommendations from memory" do
      memory_context = %{
        known: true,
        failure_patterns: [],
        dependencies: [],
        recommendations: ["Consider canary deployment."]
      }

      occurrence = Occurrence.build(@failed_result, memory_context)

      assert reasoning = occurrence["reasoning"]
      assert "Consider canary deployment." in reasoning["recommendations"]
    end
  end

  describe "build/2 with rolledback status" do
    test "produces rolledback type" do
      result = %{@failed_result | status: :rolledback}
      occurrence = Occurrence.build(result)

      assert occurrence["type"] == "deploy.run.rolledback"
      assert occurrence["severity"] == "warning"
    end
  end

  describe "persist/2" do
    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "nopea_occurrence_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      {:ok, workdir: tmp_dir}
    end

    test "writes occurrence.json to .nopea directory", %{workdir: workdir} do
      occurrence = Occurrence.build(@successful_result)
      assert :ok = Occurrence.persist(occurrence, workdir)

      json_path = Path.join([workdir, ".nopea", "occurrence.json"])
      assert File.exists?(json_path)

      {:ok, content} = File.read(json_path)
      {:ok, decoded} = Jason.decode(content)
      assert decoded["source"] == "nopea"
    end

    test "writes ETF to occurrences/ directory", %{workdir: workdir} do
      occurrence = Occurrence.build(@successful_result)
      :ok = Occurrence.persist(occurrence, workdir)

      etf_dir = Path.join([workdir, ".nopea", "occurrences"])
      assert File.exists?(etf_dir)

      files = File.ls!(etf_dir)
      assert length(files) == 1
      assert hd(files) |> String.ends_with?(".etf")
    end
  end
end

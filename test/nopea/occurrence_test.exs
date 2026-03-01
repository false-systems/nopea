defmodule Nopea.OccurrenceTest do
  use ExUnit.Case, async: true

  @successful_result %{
    service: "auth-service",
    namespace: "production",
    strategy: :direct,
    status: :completed,
    deploy_id: "01ABC",
    manifests_applied: 3,
    duration_ms: 1500,
    verified: true,
    error: nil,
    applied_resources: [
      %{
        "kind" => "Deployment",
        "metadata" => %{
          "name" => "auth-service",
          "namespace" => "production",
          "uid" => "abc-123",
          "resourceVersion" => "42"
        }
      }
    ]
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
    error: {:timeout, "connection refused to api-server"},
    applied_resources: []
  }

  describe "build/1 for successful deploys" do
    test "produces valid FALSE Protocol occurrence struct" do
      occ = Nopea.Occurrence.build(@successful_result)

      assert %FalseProtocol.Occurrence{} = occ
      assert occ.protocol_version == "1.0"
      assert occ.source == "nopea"
      assert occ.type == "deploy.run.completed"
      assert occ.severity == :info
      assert occ.outcome == :success
      assert is_binary(occ.id)
      assert %DateTime{} = occ.timestamp
    end

    test "has no error block on success" do
      occ = Nopea.Occurrence.build(@successful_result)
      assert occ.error == nil
    end

    test "has no reasoning block on success" do
      occ = Nopea.Occurrence.build(@successful_result)
      assert occ.reasoning == nil
    end

    test "has history block with steps" do
      occ = Nopea.Occurrence.build(@successful_result)

      assert %FalseProtocol.History{} = occ.history
      assert is_list(occ.history.steps)
      assert occ.history.duration_ms == 1500

      [apply_step | _] = occ.history.steps
      assert apply_step.action == "apply"
      assert apply_step.outcome == :success
      assert %DateTime{} = apply_step.timestamp
    end

    test "includes verification step when verified" do
      occ = Nopea.Occurrence.build(@successful_result)

      actions = Enum.map(occ.history.steps, & &1.action)
      assert "verify" in actions
    end

    test "has deploy_data in data field" do
      occ = Nopea.Occurrence.build(@successful_result)

      assert data = occ.data
      assert data["service"] == "auth-service"
      assert data["namespace"] == "production"
      assert data["strategy"] == "direct"
      assert data["manifests_applied"] == 3
      assert data["verified"] == true
    end

    test "sets namespace in context" do
      occ = Nopea.Occurrence.build(@successful_result)
      assert occ.context.namespace == "production"
    end

    test "builds entities from applied_resources" do
      occ = Nopea.Occurrence.build(@successful_result)

      assert [entity] = occ.context.entities
      assert entity.type == "Deployment"
      assert entity.id == "abc-123"
      assert entity.name == "auth-service"
      assert entity.namespace == "production"
      assert entity.version == "42"
      assert entity.source_of_truth == "k8s-api"
    end
  end

  describe "build/1 for failed deploys" do
    test "produces failed occurrence" do
      occ = Nopea.Occurrence.build(@failed_result)

      assert occ.type == "deploy.run.failed"
      assert occ.severity == :error
      assert occ.outcome == :failure
    end

    test "has error struct with structured details" do
      occ = Nopea.Occurrence.build(@failed_result)

      assert %FalseProtocol.Error{} = occ.error
      assert occ.error.code == "timeout"
      assert is_binary(occ.error.what_failed)
      assert String.contains?(occ.error.what_failed, "payment-svc")
    end

    test "error has why_it_matters" do
      occ = Nopea.Occurrence.build(@failed_result)

      assert is_binary(occ.error.why_it_matters)
      assert String.contains?(occ.error.why_it_matters, "production")
    end

    test "has reasoning block with low confidence without memory" do
      occ = Nopea.Occurrence.build(@failed_result)

      assert %FalseProtocol.Reasoning{} = occ.reasoning
      assert occ.reasoning.confidence == 0.3
      assert is_binary(occ.reasoning.summary)
    end

    test "history steps have action and timestamp" do
      occ = Nopea.Occurrence.build(@failed_result)

      [step] = occ.history.steps
      assert step.action == "apply"
      assert step.outcome == :failure
      assert %DateTime{} = step.timestamp
    end
  end

  describe "build/2 with memory context" do
    test "includes reasoning block with patterns_matched" do
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

      occ = Nopea.Occurrence.build(@failed_result, memory_context)

      assert %FalseProtocol.Reasoning{} = occ.reasoning
      assert is_binary(occ.reasoning.summary)
      assert occ.reasoning.confidence == 0.8

      assert [pattern] = occ.reasoning.patterns_matched
      assert %FalseProtocol.PatternMatch{} = pattern
      assert pattern.pattern_name == "timeout"
      assert pattern.confidence == 0.85
      assert pattern.times_seen == 4
    end

    test "reasoning explanation includes recommendations from memory" do
      memory_context = %{
        known: true,
        failure_patterns: [],
        dependencies: [],
        recommendations: ["Consider canary deployment."]
      }

      occ = Nopea.Occurrence.build(@failed_result, memory_context)

      assert occ.reasoning.explanation =~ "Consider canary deployment."
    end
  end

  describe "build/2 with rolledback status" do
    test "produces rolledback type with failure outcome" do
      result = %{@failed_result | status: :rolledback}
      occ = Nopea.Occurrence.build(result)

      assert occ.type == "deploy.run.rolledback"
      assert occ.severity == :warning
      assert occ.outcome == :failure
    end

    test "history includes rollback step" do
      result = %{@failed_result | status: :rolledback}
      occ = Nopea.Occurrence.build(result)

      actions = Enum.map(occ.history.steps, & &1.action)
      assert "apply" in actions
      assert "rollback" in actions
    end

    test "rollback indicated in deploy data" do
      result = %{@failed_result | status: :rolledback}
      occ = Nopea.Occurrence.build(result)

      assert occ.data["service"] == "payment-svc"
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
      occ = Nopea.Occurrence.build(@successful_result)
      assert :ok = Nopea.Occurrence.persist(occ, workdir)

      json_path = Path.join([workdir, ".nopea", "occurrence.json"])
      assert File.exists?(json_path)

      {:ok, content} = File.read(json_path)
      {:ok, decoded} = Jason.decode(content)
      assert decoded["source"] == "nopea"
      assert decoded["protocol_version"] == "1.0"
    end

    test "writes ETF to occurrences/ directory", %{workdir: workdir} do
      occ = Nopea.Occurrence.build(@successful_result)
      :ok = Nopea.Occurrence.persist(occ, workdir)

      etf_dir = Path.join([workdir, ".nopea", "occurrences"])
      assert File.exists?(etf_dir)

      files = File.ls!(etf_dir)
      assert length(files) == 1
      assert hd(files) |> String.ends_with?(".etf")
    end

    test "ETF round-trips to same struct", %{workdir: workdir} do
      occ = Nopea.Occurrence.build(@successful_result)
      :ok = Nopea.Occurrence.persist(occ, workdir)

      etf_dir = Path.join([workdir, ".nopea", "occurrences"])
      [file] = File.ls!(etf_dir)
      binary = File.read!(Path.join(etf_dir, file))
      restored = :erlang.binary_to_term(binary)

      assert restored.id == occ.id
      assert restored.source == "nopea"
      assert restored.type == occ.type
    end
  end
end

defmodule Nopea.Deploy.ResultTest do
  use ExUnit.Case, async: true

  alias Nopea.Deploy.{Spec, Result}

  @spec sample_spec() :: Spec.t()
  defp sample_spec do
    %Spec{
      service: "auth-service",
      namespace: "production",
      manifests: [%{"kind" => "Deployment"}, %{"kind" => "Service"}]
    }
  end

  describe "success/6" do
    test "builds a completed result" do
      spec = sample_spec()
      result = Result.success("01ABC", spec, :direct, [%{}, %{}], 150, true)

      assert result.deploy_id == "01ABC"
      assert result.service == "auth-service"
      assert result.namespace == "production"
      assert result.status == :completed
      assert result.strategy == :direct
      assert result.manifest_count == 2
      assert result.duration_ms == 150
      assert result.verified == true
      assert result.applied_resources == [%{}, %{}]
      assert result.error == nil
      assert %DateTime{} = result.timestamp
    end
  end

  describe "failure/5" do
    test "builds a failed result" do
      spec = sample_spec()
      result = Result.failure("01DEF", spec, :canary, :timeout, 5000)

      assert result.deploy_id == "01DEF"
      assert result.status == :failed
      assert result.strategy == :canary
      assert result.error == :timeout
      assert result.duration_ms == 5000
      assert result.verified == false
    end
  end
end

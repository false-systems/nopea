defmodule Nopea.HelpersTest do
  use ExUnit.Case, async: true

  alias Nopea.Helpers

  describe "generate_ulid/0" do
    test "returns a 26-character ULID string" do
      ulid = Helpers.generate_ulid()
      assert is_binary(ulid)
      assert String.length(ulid) == 26
    end

    test "generates unique values" do
      a = Helpers.generate_ulid()
      b = Helpers.generate_ulid()
      refute a == b
    end
  end

  describe "parse_strategy/1" do
    test "parses direct" do
      assert Helpers.parse_strategy("direct") == :direct
    end

    test "returns nil for unknown strategy" do
      assert Helpers.parse_strategy("unknown") == nil
    end

    test "returns nil for nil" do
      assert Helpers.parse_strategy(nil) == nil
    end
  end

  describe "serialize_deploy_result/1" do
    test "extracts expected fields from result struct" do
      result = %Nopea.Deploy.Result{
        deploy_id: "test-id",
        status: :completed,
        service: "api",
        namespace: "prod",
        strategy: :direct,
        duration_ms: 150,
        manifest_count: 3,
        verified: true,
        error: nil,
        applied_resources: [],
        timestamp: DateTime.utc_now()
      }

      serialized = Helpers.serialize_deploy_result(result)

      assert serialized.deploy_id == "test-id"
      assert serialized.status == :completed
      assert serialized.service == "api"
      assert serialized.namespace == "prod"
      assert serialized.strategy == :direct
      assert serialized.duration_ms == 150
      assert serialized.manifest_count == 3
      refute Map.has_key?(serialized, :error)
      refute Map.has_key?(serialized, :verified)
    end
  end
end

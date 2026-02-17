defmodule Nopea.EventsTest do
  use ExUnit.Case, async: true

  alias Nopea.Events

  describe "deploy_started/2" do
    test "creates a deployment.started event" do
      event =
        Events.deploy_started("auth-service", %{
          deploy_id: "01ABC",
          strategy: :direct,
          namespace: "production",
          manifest_count: 3
        })

      assert event.type == "dev.cdevents.deployment.started.0.1.0"
      assert event.source == "/nopea/deploy/auth-service"
      assert event.subject.id == "auth-service"
      assert event.subject.content.strategy == :direct
    end
  end

  describe "deploy_completed/2" do
    test "creates a deployment.completed event" do
      event =
        Events.deploy_completed("api-gateway", %{
          deploy_id: "01DEF",
          strategy: :canary,
          namespace: "staging",
          duration_ms: 5000,
          verified: true
        })

      assert event.type == "dev.cdevents.deployment.completed.0.1.0"
      assert event.subject.content.duration_ms == 5000
      assert event.subject.content.verified == true
    end
  end

  describe "deploy_failed/2" do
    test "creates a deployment.failed event with error" do
      event =
        Events.deploy_failed("payment-svc", %{
          deploy_id: "01GHI",
          strategy: :direct,
          namespace: "production",
          error: {:timeout, "connection refused"},
          duration_ms: 30_000
        })

      assert event.type == "dev.cdevents.deployment.failed.0.1.0"
      assert event.subject.content.error == %{type: "timeout", message: "connection refused"}
    end
  end

  describe "service_deployed/2" do
    test "creates a service.deployed event" do
      event =
        Events.service_deployed("my-app", %{
          commit: "abc123",
          namespace: "production",
          manifest_count: 5
        })

      assert event.type == "dev.cdevents.service.deployed.0.3.0"
      assert event.source == "/nopea/deploy/my-app"
      assert event.subject.content.environment.id == "production"
    end

    test "uses default namespace" do
      event = Events.service_deployed("my-app", %{commit: "abc123"})
      assert event.subject.content.environment.id == "default"
    end
  end

  describe "CDEvent struct" do
    test "new/1 creates valid event with context fields" do
      event =
        Events.new(%{
          type: :service_deployed,
          source: "/nopea/deploy/my-app",
          subject_id: "my-app",
          content: %{environment: %{id: "prod"}}
        })

      assert is_binary(event.id)
      assert String.length(event.id) == 26
      assert event.specversion == "1.0"
      assert %DateTime{} = event.timestamp
    end

    test "new/1 generates unique IDs" do
      e1 = Events.new(%{type: :service_deployed, source: "/test", subject_id: "s", content: %{}})
      e2 = Events.new(%{type: :service_deployed, source: "/test", subject_id: "s", content: %{}})
      refute e1.id == e2.id
    end

    test "supports all deployment event types" do
      types = [
        {:deploy_started, "dev.cdevents.deployment.started.0.1.0"},
        {:deploy_completed, "dev.cdevents.deployment.completed.0.1.0"},
        {:deploy_failed, "dev.cdevents.deployment.failed.0.1.0"},
        {:service_deployed, "dev.cdevents.service.deployed.0.3.0"},
        {:service_upgraded, "dev.cdevents.service.upgraded.0.3.0"}
      ]

      for {atom_type, expected} <- types do
        event = Events.new(%{type: atom_type, source: "/t", subject_id: "id", content: %{}})
        assert event.type == expected
      end
    end
  end

  describe "to_json/1" do
    test "serializes to CloudEvents-compatible JSON" do
      event =
        Events.new(%{
          type: :service_deployed,
          source: "/nopea/deploy/my-app",
          subject_id: "my-service",
          content: %{environment: %{id: "prod"}}
        })

      {:ok, json} = Events.to_json(event)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "dev.cdevents.service.deployed.0.3.0"
      assert decoded["source"] == "/nopea/deploy/my-app"
      assert decoded["specversion"] == "1.0"
      assert decoded["subject"]["id"] == "my-service"
    end
  end
end

defmodule Nopea.MCPWithMemoryTest do
  use ExUnit.Case, async: false

  alias Nopea.MCP

  setup do
    start_supervised!({Nopea.Memory, []})
    start_supervised!(Nopea.Cache)
    :ok
  end

  describe "nopea_explain with memory" do
    test "explains strategy for unknown service" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_explain",
          "arguments" => %{"service" => "new-svc", "namespace" => "default"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      content = response["result"]["content"]
      text = hd(content)["text"]
      assert text =~ "No deployment history"
      assert text =~ "direct"
    end

    test "explains strategy for known service with failures" do
      # Record failures to build memory context
      for _ <- 1..3 do
        Nopea.Memory.record_deploy(%{
          service: "fragile-svc",
          namespace: "prod",
          status: :failed,
          error: {:timeout, "connection timeout"},
          concurrent_deploys: []
        })
      end

      _ = Nopea.Memory.node_count()

      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_explain",
          "arguments" => %{"service" => "fragile-svc", "namespace" => "prod"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      content = response["result"]["content"]
      text = hd(content)["text"]
      assert text =~ "Failure patterns detected"
      assert text =~ "canary"
    end
  end

  describe "nopea_context with memory" do
    test "returns context for known service" do
      Nopea.Memory.record_deploy(%{
        service: "api-svc",
        namespace: "default",
        status: :completed,
        error: nil,
        concurrent_deploys: []
      })

      _ = Nopea.Memory.node_count()

      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_context",
          "arguments" => %{"service" => "api-svc", "namespace" => "default"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      content = response["result"]["content"]
      text = hd(content)["text"]
      decoded = Jason.decode!(text)
      assert decoded["known"] == true
      assert decoded["service"] == "api-svc"
    end
  end

  describe "nopea_history with cache" do
    test "returns state for known service" do
      Nopea.Cache.put_service_state("cached-svc", %{
        status: :completed,
        last_deploy: "01ABC",
        last_deploy_at: DateTime.utc_now()
      })

      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_history",
          "arguments" => %{"service" => "cached-svc"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      content = response["result"]["content"]
      text = hd(content)["text"]
      decoded = Jason.decode!(text)
      assert decoded["service"] == "cached-svc"
      assert decoded["state"] != nil
    end

    test "returns no history for unknown service" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_history",
          "arguments" => %{"service" => "nonexistent-svc"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      content = response["result"]["content"]
      text = hd(content)["text"]
      decoded = Jason.decode!(text)
      assert decoded["message"] == "No history found"
    end
  end
end

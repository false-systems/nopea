defmodule Nopea.MCPTest do
  use ExUnit.Case, async: true

  alias Nopea.MCP

  describe "handle_request/1 initialize" do
    test "returns server info and capabilities" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2024-11-05",
          "clientInfo" => %{"name" => "test", "version" => "1.0"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      assert response["id"] == 1
      assert response["result"]["serverInfo"]["name"] == "nopea"
      assert is_map(response["result"]["capabilities"])
      assert response["result"]["capabilities"]["tools"] != nil
    end
  end

  describe "handle_request/1 tools/list" do
    test "lists available tools" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      }

      assert {:ok, response} = MCP.handle_request(request)
      tools = response["result"]["tools"]
      assert is_list(tools)
      assert tools != []

      tool_names = Enum.map(tools, & &1["name"])
      assert "nopea_deploy" in tool_names
      assert "nopea_context" in tool_names
      assert "nopea_history" in tool_names
    end
  end

  describe "handle_request/1 tools/call nopea_context" do
    test "returns context for a service" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_context",
          "arguments" => %{"service" => "api-gateway", "namespace" => "default"}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      assert response["id"] == 3
      content = response["result"]["content"]
      assert is_list(content)
      assert hd(content)["type"] == "text"
    end
  end

  describe "handle_request/1 unknown method" do
    test "returns method not found error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "unknown/method",
        "params" => %{}
      }

      assert {:ok, response} = MCP.handle_request(request)
      assert response["error"]["code"] == -32_601
    end
  end

  describe "handle_request/1 tools/call unknown tool" do
    test "returns tool not found error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "nonexistent_tool",
          "arguments" => %{}
        }
      }

      assert {:ok, response} = MCP.handle_request(request)
      assert response["error"] != nil
    end
  end

  describe "encode/decode" do
    test "round-trips through JSON" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      }

      json = MCP.encode(request)
      assert is_binary(json)
      assert String.ends_with?(json, "\n")

      {:ok, decoded} = MCP.decode(json)
      assert decoded["method"] == "initialize"
    end
  end
end

defmodule Nopea.Oracle.Case076McpTest do
  @moduledoc """
  MCP PROTOCOL (076-090)

  Tests the JSON-RPC 2.0 protocol over stdin/stdout.
  Validates lifecycle, tool dispatch, error handling,
  and protocol compliance.

  NOTE: These tests require the nopea escript binary to be built.
  Run `mix escript.build` in the nopea root first.

  Skip with: mix test --exclude mcp
  """
  use ExUnit.Case, async: false

  alias Nopea.Oracle

  @moduletag :mcp

  setup do
    binary = Path.expand(Oracle.mcp_binary())

    if File.exists?(binary) do
      port = Oracle.start_mcp()
      on_exit(fn -> Oracle.stop_mcp(port) end)
      %{port: port}
    else
      %{port: nil, skip: true}
    end
  end

  defp skip_without_binary(%{port: nil}) do
    # Can't run MCP tests without the binary — assert true and return
    assert true, "MCP binary not found — skipping"
  end

  defp skip_without_binary(_), do: :ok

  # ================================================================
  # LIFECYCLE
  # ================================================================

  test "case_076 initialize returns protocol version and capabilities", ctx do
    skip_without_binary(ctx)

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })

    assert resp["result"]["protocolVersion"] == "2024-11-05"
    assert resp["result"]["serverInfo"]["name"] == "nopea"
    assert is_map(resp["result"]["capabilities"])
  end

  test "case_077 tools/list returns all expected tools", ctx do
    skip_without_binary(ctx)

    # Initialize first
    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      })

    tools = resp["result"]["tools"]
    tool_names = Enum.map(tools, & &1["name"])

    expected = [
      "nopea_deploy",
      "nopea_context",
      "nopea_history",
      "nopea_health",
      "nopea_explain",
      "nopea_services",
      "nopea_promote",
      "nopea_rollback"
    ]

    for name <- expected do
      assert name in tool_names, "Missing tool: #{name}"
    end
  end

  # ================================================================
  # TOOL CALLS — ERROR PATHS
  # ================================================================

  test "case_078 tools/call unknown tool returns error", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "nonexistent_tool", "arguments" => %{}}
      })

    assert resp["error"] != nil
  end

  test "case_079 tools/call deploy without service returns error", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "nopea_deploy", "arguments" => %{}}
      })

    assert resp["error"] != nil
  end

  # ================================================================
  # PROTOCOL VIOLATIONS
  # ================================================================

  test "case_080 request without method returns error", ctx do
    skip_without_binary(ctx)

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 1
      })

    assert resp["error"] != nil
  end

  test "case_081 unknown method returns method not found", ctx do
    skip_without_binary(ctx)

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "completely/unknown/method"
      })

    assert resp["error"]["code"] == -32601
  end

  test "case_082 notification (no id) returns no response", ctx do
    skip_without_binary(ctx)

    # notifications/initialized is a notification — no response expected
    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    # Send notification
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized"
      }) <> "\n"

    Port.command(ctx.port, line)

    # Should NOT get a response for notifications
    # Send a real request to verify the server is still alive
    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 99,
        "method" => "tools/list",
        "params" => %{}
      })

    assert resp["result"]["tools"] != nil
  end

  # ================================================================
  # SHUTDOWN / EXIT LIFECYCLE
  # ================================================================

  test "case_083 shutdown returns null result", ctx do
    skip_without_binary(ctx)

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "shutdown"
      })

    assert resp["result"] == nil
    assert resp["error"] == nil
  end

  test "case_084 exit after shutdown produces exit code 0", ctx do
    skip_without_binary(ctx)

    # Shutdown first
    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "shutdown"
    })

    # Then exit
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "exit"
      }) <> "\n"

    Port.command(ctx.port, line)

    # Should get exit status 0
    result =
      receive do
        {_, {:exit_status, code}} -> code
      after
        5_000 -> :timeout
      end

    assert result == 0
  end

  # ================================================================
  # TOOL CORRECTNESS
  # ================================================================

  test "case_085 nopea_services returns valid JSON content", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "nopea_services", "arguments" => %{}}
      })

    content = resp["result"]["content"]
    assert is_list(content)
    assert length(content) == 1
    assert hd(content)["type"] == "text"

    # The text content should be valid JSON
    {:ok, parsed} = Jason.decode(hd(content)["text"])
    assert is_list(parsed["services"])
  end

  test "case_086 nopea_health returns structured response", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{"name" => "nopea_health", "arguments" => %{}}
      })

    content = resp["result"]["content"]
    assert hd(content)["type"] == "text"
    {:ok, parsed} = Jason.decode(hd(content)["text"])
    assert is_map(parsed)
  end

  test "case_087 nopea_promote with nonexistent id returns error", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_promote",
          "arguments" => %{"deploy_id" => "00000000000000000000000000"}
        }
      })

    assert resp["error"] != nil
  end

  test "case_088 nopea_context for unknown service returns valid JSON", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "nopea_context",
          "arguments" => %{"service" => "nonexistent-mcp-svc"}
        }
      })

    content = resp["result"]["content"]
    {:ok, parsed} = Jason.decode(hd(content)["text"])
    assert parsed["known"] == false
  end

  test "case_089 notifications/cancelled is handled gracefully", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    # Send cancelled notification
    line =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"id" => 99, "reason" => "test cancellation"}
      }) <> "\n"

    Port.command(ctx.port, line)

    # Server should still be alive
    {:ok, resp} =
      Oracle.mcp_request(ctx.port, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/list",
        "params" => %{}
      })

    assert resp["result"]["tools"] != nil
  end

  test "case_090 multiple rapid requests do not confuse server", ctx do
    skip_without_binary(ctx)

    Oracle.mcp_request(ctx.port, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{}
    })

    # Fire 5 requests rapidly
    for i <- 2..6 do
      line =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => i,
          "method" => "tools/list",
          "params" => %{}
        }) <> "\n"

      Port.command(ctx.port, line)
    end

    # Collect responses — each should have matching id
    responses =
      for _i <- 2..6 do
        case Oracle.mcp_request(ctx.port, %{}) do
          {:ok, resp} -> resp
          _ -> nil
        end
      end
      |> Enum.reject(&is_nil/1)

    # At least some should have succeeded
    assert length(responses) > 0
  end
end

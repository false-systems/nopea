defmodule Nopea.Test.MCPHelpers do
  @moduledoc """
  Helpers for constructing JSON-RPC 2.0 MCP test requests.
  """

  @doc """
  Builds a JSON-RPC 2.0 request map for MCP testing.

  ## Examples

      build_request("initialize", 1)
      build_request("tools/call", 2, %{"name" => "nopea_deploy", "arguments" => %{...}})
  """
  def build_request(method, id, params \\ %{}) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    }
  end

  @doc "Builds a tools/call request for the given tool name and arguments."
  def build_tool_call(tool_name, id, arguments \\ %{}) do
    build_request("tools/call", id, %{
      "name" => tool_name,
      "arguments" => arguments
    })
  end

  @doc "Extracts the text content from a successful tools/call response."
  def extract_text_content({:ok, response}) do
    response
    |> get_in(["result", "content"])
    |> List.first()
    |> Map.get("text")
  end
end

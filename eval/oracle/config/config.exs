import Config

# Treat empty string API key as nil (dev mode)
api_key =
  case System.get_env("NOPEA_API_KEY") do
    nil -> nil
    "" -> nil
    key -> key
  end

config :nopea_oracle,
  base_url: System.get_env("NOPEA_URL", "http://localhost:4000"),
  api_key: api_key,
  mcp_binary: System.get_env("NOPEA_MCP_BINARY", "../../nopea"),
  settle_ms: String.to_integer(System.get_env("NOPEA_SETTLE_MS", "500"))

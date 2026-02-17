import Config

if config_env() == :prod do
  cluster_enabled = System.get_env("NOPEA_CLUSTER_ENABLED", "false") == "true"

  config :nopea,
    cluster_enabled: cluster_enabled,
    enable_router: System.get_env("NOPEA_ENABLE_ROUTER", "true") == "true",
    api_port: String.to_integer(System.get_env("NOPEA_API_PORT", "4000"))
end

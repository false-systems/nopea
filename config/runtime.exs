import Config

if config_env() == :prod do
  cluster_enabled = System.get_env("NOPEA_CLUSTER_ENABLED", "false") == "true"

  cluster_strategy =
    case System.get_env("NOPEA_CLUSTER_STRATEGY") do
      "kubernetes_dns" -> :kubernetes_dns
      "gossip" -> :gossip
      "epmd" -> :epmd
      _ -> :kubernetes_dns
    end

  cluster_hosts =
    case System.get_env("NOPEA_CLUSTER_HOSTS") do
      nil ->
        []

      hosts ->
        hosts
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_atom(String.trim(&1)))
    end

  cluster_polling_interval =
    case System.get_env("NOPEA_CLUSTER_POLLING_INTERVAL") do
      nil -> 5_000
      val -> String.to_integer(val)
    end

  cluster_gossip_port =
    case System.get_env("NOPEA_CLUSTER_GOSSIP_PORT") do
      nil -> 45_892
      val -> String.to_integer(val)
    end

  config :nopea,
    cluster_enabled: cluster_enabled,
    cluster_strategy: cluster_strategy,
    cluster_service: System.get_env("NOPEA_CLUSTER_SERVICE", "nopea-headless"),
    cluster_app_name: System.get_env("NOPEA_CLUSTER_APP_NAME", "nopea"),
    pod_namespace: System.get_env("NOPEA_POD_NAMESPACE", "default"),
    cluster_polling_interval: cluster_polling_interval,
    cluster_gossip_port: cluster_gossip_port,
    cluster_gossip_secret: System.get_env("NOPEA_CLUSTER_GOSSIP_SECRET"),
    cluster_hosts: cluster_hosts,
    enable_router: System.get_env("NOPEA_ENABLE_ROUTER", "true") == "true",
    api_port: String.to_integer(System.get_env("NOPEA_API_PORT", "4000"))
end

import Config

config :nopea,
  enable_deploy_supervisor: true,
  enable_memory: true,
  enable_cache: true

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :service,
    :deploy_id,
    :namespace,
    :strategy,
    :error,
    :reason,
    :duration_ms,
    :resource,
    :stacktrace,
    :cooldown_ms,
    :queued,
    :node_count,
    :relationship_count,
    :auto_selected,
    :verified
  ]

import_config "#{config_env()}.exs"

import Config

config :nopea,
  enable_deploy_supervisor: true,
  enable_memory: true,
  enable_cache: true

import_config "#{config_env()}.exs"

import Config

config :nopea,
  enable_deploy_supervisor: false,
  enable_memory: false,
  enable_cache: false,
  enable_router: false,
  enable_metrics: false,
  # Dummy K8s conn marker — actual struct set in test_helper.exs
  k8s_conn: :test_dummy

config :logger, level: :warning

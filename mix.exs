defmodule Nopea.MixProject do
  use Mix.Project

  def project do
    [
      app: :nopea,
      version: "0.2.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [main_module: Nopea.CLI],
      description: "AI-native deployment tool with memory",
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Nopea.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # K8s client
      {:k8s, "~> 2.6"},

      # Distributed Erlang clustering
      {:libcluster, "~> 3.3"},
      {:horde, "~> 0.9"},

      # YAML parsing
      {:yaml_elixir, "~> 2.9"},

      # HTTP client (for CDEvents)
      {:req, "~> 0.5"},

      # JSON
      {:jason, "~> 1.4"},

      # Web server (for API)
      {:plug_cowboy, "~> 2.7"},

      # Telemetry & Metrics
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_metrics_prometheus_core, "~> 1.2"},

      # Dev/Test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp package do
    [
      name: "nopea",
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/yairfalse/nopea"}
    ]
  end
end

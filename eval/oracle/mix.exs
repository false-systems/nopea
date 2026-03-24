defmodule Nopea.Oracle.MixProject do
  use Mix.Project

  def project do
    [
      app: :nopea_oracle,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: false,
      deps: deps(),
      aliases: [test: "test --no-start"]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end

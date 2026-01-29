defmodule AgentCore.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AgentCore.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ai, in_umbrella: true},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end

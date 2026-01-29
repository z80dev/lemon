defmodule CodingAgentUi.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent_ui,
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
      mod: {CodingAgentUi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:coding_agent, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:uuid, "~> 1.1"}
    ]
  end
end

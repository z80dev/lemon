defmodule LemonPlatformTest.MixProject do
  use Mix.Project

  def project do
    [
      app: :lemon_platform_test,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      # The self-validation suites in test/compliance run the templates against
      # the platform's own implementations, which covers 95%+ of the macro
      # bodies. The uncovered remainder is the branches only a *failing*
      # implementation reaches (the flunk paths).
      test_coverage: [summary: [threshold: 90]],
      deps: deps(),
      name: "LemonPlatformTest",
      docs: docs()
    ]
  end

  defp docs do
    [
      main: "LemonPlatformTest",
      source_url: "https://github.com/z80dev/lemon",
      source_ref: "main",
      formatters: ["html"],
      groups_for_modules: [
        "Case templates": [
          LemonPlatformTest.BackendCase,
          LemonPlatformTest.PluginCase,
          LemonPlatformTest.EngineCase,
          LemonPlatformTest.ProviderCase
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # One dep per behaviour the kit tests. The kit is a leaf: nothing in the
      # platform depends on it, so these edges cannot create a cycle.
      {:lemon_core, in_umbrella: true},
      {:lemon_channels, in_umbrella: true},
      {:lemon_gateway, in_umbrella: true},
      {:lemon_memory, in_umbrella: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

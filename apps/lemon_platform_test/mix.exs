Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonPlatformTest.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_platform_test,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # The self-validation suites in test/compliance run the templates against
      # the platform's own implementations, which covers 95%+ of the macro
      # bodies. The uncovered remainder is the branches only a *failing*
      # implementation reaches (the flunk paths).
      test_coverage: [summary: [threshold: 90]],
      deps: deps(),
      name: "lemon_platform_test",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "Contract-test kit for the Lemon platform's extension behaviours: ExUnit " <>
      "case templates that hold your Plugin, Engine, Store backend or memory " <>
      "Provider implementation to the documented contract."
  end

  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_platform_test),
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_platform_test/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "main",
      formatters: ["html"],
      groups_for_modules: [
        "Case templates": [
          LemonPlatformTest.BackendCase,
          LemonPlatformTest.PluginCase,
          LemonPlatformTest.EngineCase,
          LemonPlatformTest.ProviderCase,
          LemonPlatformTest.EventsCase
        ],
        "Test doubles": [
          LemonPlatformTest.FakeLLM
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    Lemon.HexPackage.deps([
      # One dep per behaviour/tool the kit provides, and every one is
      # `optional: true`. A third party pulls in only the platform apps whose
      # case they actually use — someone testing a Plugin should not also
      # compile lemon_gateway, exqlite and nostrum as test deps. Each case
      # template guards on `Code.ensure_loaded?` of its target and raises a
      # pointed "add this dep" error if the app is absent (see below).
      #
      #   BackendCase  -> lemon_core           EngineCase   -> lemon_gateway
      #   EventsCase   -> lemon_core           ProviderCase -> lemon_memory
      #   PluginCase   -> lemon_channels       FakeLLM      -> ai + agent_core
      #
      # The kit is a leaf: nothing in the platform depends on it, so these edges
      # cannot create a cycle. In the umbrella all siblings are present, so the
      # self-validation suites in test/compliance still compile and pass.
      {:lemon_core, in_umbrella: true, optional: true},
      {:lemon_channels, in_umbrella: true, optional: true},
      {:lemon_gateway, in_umbrella: true, optional: true},
      {:lemon_memory, in_umbrella: true, optional: true},
      {:ai, in_umbrella: true, optional: true},
      {:agent_core, in_umbrella: true, optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end

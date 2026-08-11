Code.require_file("../../hex_package.exs", __DIR__)

defmodule LemonAi.MixProject do
  use Mix.Project

  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_ai,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 64]],
      deps: deps(),
      name: "lemon_ai",
      description: description(),
      package: package(),
      docs: docs()
    ]
  end

  defp description do
    "A provider-agnostic LLM client for Elixir: 27 providers (Anthropic, OpenAI, " <>
      "Google, Bedrock, Azure, Groq, Mistral, and more) behind one streaming API, " <>
      "with a model registry, circuit breaking, rate limiting and cost tracking."
  end

  # The OTP application stays :lemon_ai; the hex package is lemon_ai.
  defp package do
    [
      name: Lemon.HexPackage.name(:lemon_ai),
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_ai/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url: @source_url,
      source_ref: "main",
      formatters: ["html"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LemonAi.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    Lemon.HexPackage.deps([
      # HTTP client with streaming support
      {:req, "~> 0.5"},
      # JSON encoding/decoding
      {:jason, "~> 1.4"},
      # Options validation
      {:nimble_options, "~> 1.1"},
      # Required for Req.Test stubs
      {:plug, "~> 1.16", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end
end

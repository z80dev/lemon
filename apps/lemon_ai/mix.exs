defmodule LemonAi.MixProject do
  use Mix.Project

  @version "0.2.1"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. Inside the lemon repo it sits at
  # apps/lemon_ai/mix.exs under the umbrella's mix.exs and shares the
  # umbrella's build, deps and lockfile; anywhere else (deps/lemon_ai in a
  # consumer, an unpacked tarball) it is a standalone package.
  # LEMON_HEX_PUBLISH=1 forces the standalone form inside the repo.
  @umbrella Path.basename(Path.dirname(__DIR__)) == "apps" and
              File.regular?(Path.expand("../../mix.exs", __DIR__)) and
              System.get_env("LEMON_HEX_PUBLISH") not in ["1", "true"]

  def project do
    [
      app: :lemon_ai,
      version: @version,
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 64]],
      deps: deps(),
      name: "lemon_ai",
      description: description(),
      package: package(),
      docs: docs()
    ] ++ umbrella_paths()
  end

  defp umbrella_paths do
    if @umbrella do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
  end

  defp description do
    "A provider-agnostic LLM client for Elixir: 27 providers (Anthropic, OpenAI, " <>
      "Google, Bedrock, Azure, Groq, Mistral, and more) behind one streaming API, " <>
      "with a model registry, circuit breaking, rate limiting and cost tracking."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      # `files` globs the working tree, not the index, so anything gitignored
      # that happens to exist under priv/ locally would otherwise ship.
      exclude_patterns: [~r/\.env/, ~r/node_modules/],
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
    [
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
    ]
  end
end

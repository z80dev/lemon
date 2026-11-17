defmodule LemonAgent.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. Inside the lemon repo it sits at
  # apps/lemon_agent/mix.exs under the umbrella's mix.exs: it shares the
  # umbrella's build, deps and lockfile, and sibling packages resolve
  # in_umbrella. Anywhere else (deps/lemon_agent in a consumer, an unpacked
  # tarball) sibling packages resolve from hex. LEMON_HEX_PUBLISH=1 forces the
  # hex form inside the repo: `mix hex.build` records only hex dependencies and
  # refuses to build with an in_umbrella one.
  @umbrella Path.basename(Path.dirname(__DIR__)) == "apps" and
              File.regular?(Path.expand("../../mix.exs", __DIR__)) and
              System.get_env("LEMON_HEX_PUBLISH") not in ["1", "true"]

  # What a published release requires of its sibling Lemon packages.
  @lemon_requirements %{lemon_ai: "~> 0.3", lemon_core: "~> 0.3"}

  def project do
    [
      app: :lemon_agent,
      version: @version,
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 71]],
      deps: deps(),
      name: "lemon_agent",
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
    "Agent runtime for the BEAM: the agentic loop with streaming events, " <>
      "supervised stateful agents, a tool registry, subagents, model routing " <>
      "and credentials, and workspace coordination stores."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_agent/CHANGELOG.md"
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
      mod: {LemonAgent.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    lemon_deps([
      {:lemon_ai, in_umbrella: true},
      {:lemon_core, in_umbrella: true},
      {:req, "~> 0.6.0"},
      {:jason, "~> 1.4"},
      {:opentelemetry_api, "~> 1.5", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      # API documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ])
  end

  # Sibling Lemon packages are declared `in_umbrella: true` (the architecture
  # check reads that form). Outside the umbrella each becomes a hex requirement
  # on the current release line. `optional: true` only means something to hex —
  # Mix rejects it on in_umbrella deps — so the umbrella form drops it.
  defp lemon_deps(deps) do
    Enum.map(deps, fn
      {app, opts} = dep when is_list(opts) ->
        if Keyword.get(opts, :in_umbrella, false) do
          if @umbrella,
            do: {app, Keyword.delete(opts, :optional)},
            else: {app, Map.fetch!(@lemon_requirements, app), Keyword.delete(opts, :in_umbrella)}
        else
          dep
        end

      dep ->
        dep
    end)
  end
end

defmodule LemonMemory.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. Inside the lemon repo it sits at
  # apps/lemon_memory/mix.exs under the umbrella's mix.exs: it shares the
  # umbrella's build, deps and lockfile, and sibling packages resolve
  # in_umbrella. Anywhere else (deps/lemon_memory in a consumer, an unpacked
  # tarball) sibling packages resolve from hex. LEMON_HEX_PUBLISH=1 forces the
  # hex form inside the repo: `mix hex.build` records only hex dependencies and
  # refuses to build with an in_umbrella one.
  @umbrella Path.basename(Path.dirname(__DIR__)) == "apps" and
              File.regular?(Path.expand("../../mix.exs", __DIR__)) and
              System.get_env("LEMON_HEX_PUBLISH") not in ["1", "true"]

  # What a published release requires of its sibling Lemon packages. The
  # published packages ship together on one 0.x release line and every 0.x
  # minor may break, so the requirement is derived from @version and admits
  # patch releases of the same minor only ("~> 0.3.0" for 0.3.x; never 0.4).
  @lemon_requirement with {:ok, v} <- Version.parse(@version), do: "~> #{v.major}.#{v.minor}.0"

  def project do
    [
      app: :lemon_memory,
      version: @version,
      test_pattern: "*_test.exs",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      # Floor, not a target: `SessionSearch` now has a direct suite, but
      # `mix lemon.memory` is still untested, so the threshold stays where the
      # moved suites put it rather than tracking each gain.
      test_coverage: [summary: [threshold: 60]],
      deps: deps(),
      name: "lemon_memory",
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
    "Durable memory for agents: document schema, SQLite-backed full-text " <>
      "store, a provider behaviour with isolated fan-out search, run ingest, " <>
      "redaction and task fingerprints."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/apps/lemon_memory/CHANGELOG.md"
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

  def application do
    [
      extra_applications: [:logger],
      mod: {LemonMemory.Application, []}
    ]
  end

  defp deps do
    lemon_deps([
      {:lemon_core, in_umbrella: true},
      # Durable memory is SQLite-backed; unlike lemon_core, which only needs it
      # for optional subsystems, this app's whole reason to exist is the store.
      {:exqlite, "~> 0.43.0"},
      {:jason, "~> 1.4"},
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
            else: {app, @lemon_requirement, Keyword.delete(opts, :in_umbrella)}
        else
          dep
        end

      dep ->
        dep
    end)
  end
end

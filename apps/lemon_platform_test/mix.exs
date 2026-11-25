defmodule LemonPlatformTest.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/z80dev/lemon"

  # This file ships verbatim in the hex tarball, so it must not read anything
  # outside its own directory. Inside the lemon repo it sits at
  # apps/lemon_platform_test/mix.exs under the umbrella's mix.exs: it shares
  # the umbrella's build, deps and lockfile, and sibling packages resolve
  # in_umbrella. Anywhere else (deps/lemon_platform_test in a consumer, an
  # unpacked tarball) sibling packages resolve from hex. LEMON_HEX_PUBLISH=1
  # forces the hex form inside the repo: `mix hex.build` records only hex
  # dependencies and refuses to build with an in_umbrella one.
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
      app: :lemon_platform_test,
      version: @version,
      test_pattern: "*_test.exs",
      elixir: "~> 1.17",
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
    "Shared ExUnit helpers and contract-test suites for Lemon extension " <>
      "behaviours, including Store backends and memory providers."
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
      # PluginCase targets lemon_channels, which is not published, so it is
      # repository-only: a Hex consumer could never satisfy it.
      # scripts/verify_packages fails if a packaged module references a
      # module outside the published packages.
      exclude_patterns: [~r{^lib/lemon_platform_test/plugin_case\.ex$}],
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
        "Case templates":
          [LemonPlatformTest.BackendCase] ++
            if(@umbrella, do: [LemonPlatformTest.PluginCase], else: []) ++
            [LemonPlatformTest.ProviderCase, LemonPlatformTest.EventsCase],
        "Test doubles": [
          LemonPlatformTest.FakeLLM
        ]
      ],
      # The published docs describe the published modules only.
      filter_modules: fn module, _metadata ->
        @umbrella or module != LemonPlatformTest.PluginCase
      end
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    # lemon_channels is not published to hex, so PluginCase and its target
    # exist only inside the umbrella (and in path dependencies on a checkout);
    # the Hex package excludes PluginCase.
    channels = if @umbrella, do: [{:lemon_channels, in_umbrella: true}], else: []

    lemon_deps([
      # One dep per behaviour/tool the kit provides, and every one is
      # `optional: true`. A third party pulls in only the platform apps whose
      # case they actually use — someone testing a Store backend should not
      # also compile exqlite as a test dep. Each case template guards on
      # `Code.ensure_loaded?` of its target and raises a pointed "add this dep"
      # error if the app is absent (see LemonPlatformTest.require_dep!/3).
      #
      #   BackendCase        -> lemon_core     ProviderCase -> lemon_memory
      #   EventsCase         -> lemon_core     FakeLLM      -> ai + agent
      #   PluginCase         -> lemon_channels (umbrella only)
      #
      # Product apps only consume the kit in tests. In the umbrella all
      # siblings are present for the self-validation suites in test/compliance.
      {:lemon_core, in_umbrella: true, optional: true},
      {:lemon_memory, in_umbrella: true, optional: true},
      {:lemon_ai, in_umbrella: true, optional: true},
      {:lemon_agent, in_umbrella: true, optional: true},
      {:telemetry, "~> 1.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]) ++ channels
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

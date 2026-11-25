defmodule LemonCore.Quality.ArchitectureCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.{ArchitectureCheck, ArchitecturePolicy}

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "repository" do
    test "satisfies every architecture rule" do
      assert {:ok, report} = ArchitectureCheck.run(root: @repo_root)
      assert report.issue_count == 0
      assert report.apps_checked == map_size(ArchitecturePolicy.app_namespaces())
    end

    test "declares the MCP client inside lemon_skills with no lemon_mcp app" do
      deps = ArchitectureCheck.actual_direct_deps(@repo_root)

      refute Map.has_key?(deps, :lemon_mcp)
      refute Enum.any?(deps, fn {_app, targets} -> :lemon_mcp in targets end)
      refute :lemon_skills in Map.get(deps, :lemon_mcp, [])
      assert "LemonMCP" in ArchitecturePolicy.app_namespaces().lemon_skills
      assert ArchitectureCheck.owner_for_module("LemonMCP.Client") == :lemon_skills
    end
  end

  describe "policy" do
    test "names roles instead of restating mix.exs" do
      refute function_exported?(ArchitecturePolicy, :allowed_direct_deps, 0)
      refute function_exported?(ArchitecturePolicy, :target_allowed_direct_deps, 0)
      assert ArchitecturePolicy.foundations() == [:lemon_ai, :lemon_core]
      assert :lemon_platform_test in ArchitecturePolicy.test_kits()
      assert :lemon_honcho in ArchitecturePolicy.satellites()
    end
  end

  describe "mix.exs parsing" do
    test "reads dependency literals with options and splits test-only edges" do
      root = tmp_umbrella()

      write_mix(root, :lemon_gateway, [
        "{:lemon_channels, in_umbrella: true, runtime: false}",
        "{:lemon_core, in_umbrella: true}",
        "{:lemon_platform_test, in_umbrella: true, only: :test, runtime: false}",
        "{:external_dep, \"~> 1.0\"}",
        "{:path_dep, path: \"../path_dep\"}"
      ])

      assert ArchitectureCheck.actual_direct_deps(root).lemon_gateway ==
               [:lemon_channels, :lemon_core, :lemon_platform_test]

      assert ArchitectureCheck.lib_dependencies(root).lemon_gateway ==
               [:lemon_channels, :lemon_core]

      assert ArchitectureCheck.test_dependencies(root).lemon_gateway == [:lemon_platform_test]
    end

    test "reads dependency lists wrapped by a package helper" do
      root = tmp_umbrella()

      write_mix(
        root,
        :lemon_gateway,
        [
          "{:lemon_agent, in_umbrella: true}",
          "{:lemon_core, in_umbrella: true}"
        ],
        wrap: true
      )

      assert ArchitectureCheck.actual_direct_deps(root).lemon_gateway ==
               [:lemon_agent, :lemon_core]
    end
  end

  describe "hidden reference forms" do
    setup do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [])
      write_app(root, :lemon_agent, [:lemon_core])
      %{root: root}
    end

    test "flags a quoted atom naming a non-dependency", %{root: root} do
      write_source(root, :lemon_agent, ~S|def m, do: :"Elixir.LemonRouter.Policy"|)

      assert issue?(
               root,
               :forbidden_namespace_reference,
               ~s(Quoted atom :"Elixir.LemonRouter.Policy")
             )
    end

    test "flags Module.concat with concatenated namespace literals", %{root: root} do
      write_source(root, :lemon_agent, ~S|def m, do: Module.concat(["Lemon" <> "MCP", "Client"])|)

      assert issue?(
               root,
               :forbidden_namespace_reference,
               "Module.concat building LemonMCP.Client"
             )
    end

    test "flags app-env access to a non-dependency", %{root: root} do
      write_source(root, :lemon_agent, ~S|def m, do: Application.get_env(:lemon_gateway, :port)|)
      write_app(root, :lemon_gateway, [:lemon_core])

      assert issue?(
               root,
               :forbidden_namespace_reference,
               "Application env access to :lemon_gateway"
             )
    end

    test "flags Erlang app-env access to a non-dependency", %{root: root} do
      write_source(root, :lemon_agent, ~S|def m, do: :application.get_env(:lemon_gateway, :port)|)
      write_app(root, :lemon_gateway, [:lemon_core])

      assert issue?(
               root,
               :forbidden_namespace_reference,
               "Application env access to :lemon_gateway"
             )
    end

    test "rejects hidden forms even toward a dependency", %{root: root} do
      write_source(root, :lemon_agent, """
      def a, do: :"Elixir.LemonCore.Bus"
      def b, do: Module.concat([LemonCore, "Store"])
      """)

      assert issue?(root, :hidden_module_reference, ~s(Quoted atom :"Elixir.LemonCore.Bus"))
      assert issue?(root, :hidden_module_reference, "Module.concat building LemonCore.Store")
    end

    test "accepts aliases and app env of the app itself and its dependencies", %{root: root} do
      write_source(root, :lemon_agent, """
      def a, do: LemonCore.Bus.topic(:system)
      def b, do: Application.get_env(:lemon_agent, :x)
      def c, do: Application.get_env(:lemon_core, :y)
      """)

      {_status, report} = ArchitectureCheck.run(root: root)

      refute Enum.any?(report.issues, &(&1.app == :lemon_agent))
    end
  end

  describe "config/*.exs" do
    setup do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [])
      write_app(root, :lemon_agent, [:lemon_core], source: "def a, do: LemonCore.Bus")
      write_app(root, :lemon_memory, [:lemon_core], source: "def a, do: LemonCore.Bus")
      %{root: root}
    end

    test "flags a module handed to an unrelated app", %{root: root} do
      write_config(root, "config :lemon_memory, :provider, LemonAgent.Provider\n")

      assert issue?(
               root,
               :config_module_reference,
               "config :lemon_memory names LemonAgent.Provider (owned by lemon_agent)"
             )
    end

    test "accepts a provider registered with an app it depends on", %{root: root} do
      write_config(root, "config :lemon_core, :providers, [LemonAgent.Provider]\n")

      {_status, report} = ArchitectureCheck.run(root: root)
      refute Enum.any?(report.issues, &(&1.code == :config_module_reference))
    end
  end

  describe "graph rules" do
    test "a foundation may not declare an umbrella dependency" do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [])
      write_app(root, :lemon_ai, [:lemon_core], source: "def a, do: LemonCore.Bus")

      assert issue?(root, :foundation_dependency, "Foundation lemon_ai")
    end

    test "nothing may depend on a satellite" do
      root = tmp_umbrella()
      write_app(root, :lemon_honcho, [])
      write_app(root, :lemon_agent, [:lemon_honcho], source: "def a, do: LemonHoncho.X")

      assert issue?(root, :satellite_dependent, "lemon_agent depends on satellite lemon_honcho")
    end

    test "a test kit may only be an `only: :test` dependency" do
      root = tmp_umbrella()
      write_app(root, :lemon_platform_test, [])

      write_app(root, :lemon_agent, [:lemon_platform_test],
        source: "def a, do: LemonPlatformTest.X"
      )

      assert issue?(root, :test_kit_runtime_dependency, "test kit lemon_platform_test")
    end

    test "a lib edge needs a lib reference" do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [])
      write_app(root, :lemon_agent, [:lemon_core])

      assert issue?(
               root,
               :unreferenced_dependency,
               "lemon_agent declares lib dependency lemon_core"
             )
    end

    test "lib code may not reach an `only: :test` dependency" do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [])

      write_mix(root, :lemon_agent, ["{:lemon_core, in_umbrella: true, only: :test}"])
      write_source(root, :lemon_agent, "def a, do: LemonCore.Bus")

      assert issue?(root, :test_dependency_in_lib, "an `only: :test` dependency of lemon_agent")
    end

    test "declared edges must be acyclic" do
      root = tmp_umbrella()
      write_app(root, :lemon_media, [:lemon_memory], source: "def a, do: LemonMemory.X")
      write_app(root, :lemon_memory, [:lemon_media], source: "def a, do: LemonMedia.X")

      assert issue?(root, :dependency_cycle, "lemon_media -> lemon_memory -> lemon_media")
    end

    test "unused reference seams and config bindings are stale" do
      root = tmp_umbrella()
      write_app(root, :lemon_gateway, [])
      write_app(root, :lemon_router, [])

      assert issue?(root, :stale_reference_exception, "lemon_gateway -> lemon_ai")
      assert issue?(root, :stale_config_binding, "lemon_router -> lemon_gateway")
    end

    test "apps without namespace ownership are unknown" do
      root = tmp_umbrella()
      write_app(root, :mystery_app, [])

      assert issue?(root, :unknown_app, "mystery_app")
      assert issue?(root, :missing_app, "lemon_core")
    end

    test "unparseable sources are reported" do
      root = tmp_umbrella()
      write_app(root, :lemon_core, [], source: "def invalid end")

      assert issue?(root, :source_parse_error, "apps/lemon_core/lib/lemon_core.ex")
    end
  end

  # ---------------------------------------------------------------------------

  defp issue?(root, code, fragment) do
    assert {:error, report} = ArchitectureCheck.run(root: root)
    Enum.any?(report.issues, &(&1.code == code and &1.message =~ fragment))
  end

  defp tmp_umbrella do
    root = Path.join(System.tmp_dir!(), "arch_check_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "apps"))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_app(root, app, deps, opts \\ []) do
    write_mix(root, app, Enum.map(deps, &"{:#{&1}, in_umbrella: true}"))
    write_source(root, app, Keyword.get(opts, :source, ""))
  end

  defp write_mix(root, app, dep_literals, opts \\ []) do
    dir = Path.join([root, "apps", to_string(app)])
    File.mkdir_p!(Path.join(dir, "lib"))
    list = "[" <> Enum.join(dep_literals, ", ") <> "]"
    body = if opts[:wrap], do: "lemon_deps(#{list})", else: list

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule #{Macro.camelize(to_string(app))}.MixProject do
      use Mix.Project

      def project, do: [app: :#{app}, version: "0.1.0", deps: deps()]

      defp deps do
        #{body}
      end
    end
    """)
  end

  defp write_source(root, app, body) do
    module =
      ArchitecturePolicy.app_namespaces() |> Map.get(app, [Macro.camelize("#{app}")]) |> hd()

    path = Path.join([root, "apps", to_string(app), "lib", "#{app}.ex"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule #{module}.Probe do\n#{body}\nend\n")
  end

  defp write_config(root, source) do
    File.mkdir_p!(Path.join(root, "config"))
    File.write!(Path.join(root, "config/config.exs"), "import Config\n" <> source)
  end
end

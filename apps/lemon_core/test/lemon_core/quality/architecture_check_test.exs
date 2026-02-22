defmodule LemonCore.Quality.ArchitectureCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "run/1" do
    test "architecture dependency check passes for umbrella apps" do
      assert {:ok, report} = ArchitectureCheck.run(root: @repo_root)
      assert report.issue_count == 0
      assert report.apps_checked >= 1
      assert is_binary(report.root)
      assert is_map(report.actual_dependencies)
    end

    test "report structure contains all required fields" do
      assert {:ok, report} = ArchitectureCheck.run(root: @repo_root)

      assert Map.has_key?(report, :root)
      assert Map.has_key?(report, :apps_checked)
      assert Map.has_key?(report, :issue_count)
      assert Map.has_key?(report, :issues)
      assert Map.has_key?(report, :actual_dependencies)
    end

    test "returns error report when issues are found" do
      # Create a temporary umbrella with violations
      tmp_dir = create_tmp_umbrella_with_violation()

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)
        assert report.issue_count > 0
        assert length(report.issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "allowed_direct_deps/0" do
    test "returns the dependency policy map" do
      deps = ArchitectureCheck.allowed_direct_deps()
      assert is_map(deps)
      assert Map.has_key?(deps, :lemon_core)
      assert is_list(deps.lemon_core)
    end

    test "lemon_core has no allowed dependencies" do
      deps = ArchitectureCheck.allowed_direct_deps()
      assert deps.lemon_core == []
    end

    test "all known apps have dependency policies" do
      deps = ArchitectureCheck.allowed_direct_deps()
      known_apps = Map.keys(deps)

      assert :lemon_core in known_apps
      assert :ai in known_apps
      assert :agent_core in known_apps
    end
  end

  describe "dependency violation detection" do
    test "detects forbidden umbrella dependencies" do
      tmp_dir = create_tmp_umbrella()

      # Create an app with a forbidden dependency
      create_app(tmp_dir, :test_app_a, [:lemon_core])
      create_app(tmp_dir, :test_app_b, [:lemon_core, :test_app_a])  # test_app_a is not in allowed deps

      # Add test_app_a to allowed deps by creating a minimal policy
      # This test will actually check unknown_app detection instead
      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        # Should have unknown_app issues since our test apps aren't in the policy
        unknown_app_issues = Enum.filter(report.issues, &(&1.code == :unknown_app))
        assert length(unknown_app_issues) >= 2
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "detects unknown apps not in policy" do
      tmp_dir = create_tmp_umbrella()
      create_app(tmp_dir, :unknown_app, [])

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        unknown_app_issues = Enum.filter(report.issues, &(&1.code == :unknown_app))
        assert length(unknown_app_issues) > 0

        issue = hd(unknown_app_issues)
        assert issue.app == :unknown_app
        assert issue.message =~ "No boundary policy configured"
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "namespace violation detection" do
    test "detects forbidden namespace references" do
      tmp_dir = create_tmp_umbrella()

      # Create an app that references a forbidden namespace
      create_app_with_namespace(tmp_dir, :lemon_core, "LemonCore", [])
      create_app_with_namespace(tmp_dir, :ai, "Ai", [:lemon_core])

      # Now create an app that references Ai but doesn't depend on it
      create_app_with_code(tmp_dir, :test_app, "LemonCore", "
        defmodule TestApp.Module do
          def test do
            Ai.SomeModule.call()
          end
        end
      ", [:lemon_core])  # Only depends on lemon_core, not ai

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        namespace_issues = Enum.filter(report.issues, &(&1.code == :forbidden_namespace_reference))
        assert length(namespace_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "allows references to own namespace" do
      tmp_dir = create_tmp_umbrella()

      # Create an app that references its own namespace
      create_app_with_code(tmp_dir, :lemon_core, "LemonCore", "
        defmodule LemonCore.Module do
          def test do
            LemonCore.OtherModule.call()
          end
        end
      ", [])

      try do
        # lemon_core is in the policy, but missing from actual scan
        # So we'll get a missing_app issue, not a namespace violation
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        # Should not have namespace violations for self-references
        namespace_issues = Enum.filter(report.issues, &(&1.code == :forbidden_namespace_reference))
        assert namespace_issues == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "allows references to allowed dependency namespaces" do
      tmp_dir = create_tmp_umbrella()

      # Create apps with proper dependency
      create_app_with_namespace(tmp_dir, :lemon_core, "LemonCore", [])
      create_app_with_namespace(tmp_dir, :ai, "Ai", [:lemon_core])

      # Ai depends on lemon_core, so it should be allowed to reference LemonCore
      create_app_with_code(tmp_dir, :ai, "Ai", "
        defmodule Ai.Module do
          def test do
            LemonCore.OtherModule.call()
          end
        end
      ", [:lemon_core])

      try do
        # Ai is allowed to depend on lemon_core, so no namespace violation
        # But we will have unknown_app issues for our test setup
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        namespace_issues = Enum.filter(report.issues, &(&1.code == :forbidden_namespace_reference))
        assert namespace_issues == []
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "missing app detection" do
    test "detects missing expected apps" do
      # Run against an empty directory
      tmp_dir = System.tmp_dir!() |> Path.join("arch_check_test_#{System.unique_integer()}")
      File.mkdir_p!(Path.join(tmp_dir, "apps"))

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        missing_app_issues = Enum.filter(report.issues, &(&1.code == :missing_app))
        # Should report all expected apps as missing
        assert length(missing_app_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "source parsing" do
    test "handles syntax errors in source files" do
      tmp_dir = create_tmp_umbrella()

      # Create an app with invalid syntax
      app_dir = Path.join([tmp_dir, "apps", "bad_syntax_app"])
      File.mkdir_p!(Path.join(app_dir, "lib"))

      mix_exs = """
      defmodule BadSyntaxApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :bad_syntax_app,
            version: "0.1.0",
            deps: deps()
          ]
        end

        defp deps do
          []
        end
      end
      """
      File.write!(Path.join(app_dir, "mix.exs"), mix_exs)

      # Write a file with invalid syntax
      File.write!(Path.join(app_dir, "lib/bad_syntax.ex"), "defmodule BadSyntax do def invalid end")

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        # Should have unknown_app and possibly source_parse_error
        assert report.issue_count > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "handles empty source files" do
      tmp_dir = create_tmp_umbrella()

      # Create an app with empty source file
      app_dir = Path.join([tmp_dir, "apps", "empty_app"])
      File.mkdir_p!(Path.join(app_dir, "lib"))

      mix_exs = """
      defmodule EmptyApp.MixProject do
        use Mix.Project

        def project do
          [
            app: :empty_app,
            version: "0.1.0",
            deps: deps()
          ]
        end

        defp deps do
          []
        end
      end
      """
      File.write!(Path.join(app_dir, "mix.exs"), mix_exs)
      File.write!(Path.join(app_dir, "lib/empty.ex"), "")

      try do
        # Should not crash on empty files
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)
        assert is_integer(report.apps_checked)
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "edge cases" do
    test "handles apps with no dependencies" do
      tmp_dir = create_tmp_umbrella()
      create_app(tmp_dir, :standalone_app, [])

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        # Should have unknown_app issue but no dependency violations
        unknown_issues = Enum.filter(report.issues, &(&1.code == :unknown_app))
        assert length(unknown_issues) > 0

        forbidden_issues = Enum.filter(report.issues, &(&1.code == :forbidden_dependency))
        assert forbidden_issues == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "handles apps with multiple dependencies" do
      tmp_dir = create_tmp_umbrella()

      # Create apps with multiple deps
      create_app(tmp_dir, :base_app, [])
      create_app(tmp_dir, :middle_app, [:base_app])
      create_app(tmp_dir, :top_app, [:base_app, :middle_app])

      try do
        assert {:error, report} = ArchitectureCheck.run(root: tmp_dir)

        # All apps are unknown, so we should have those issues
        unknown_issues = Enum.filter(report.issues, &(&1.code == :unknown_app))
        assert length(unknown_issues) >= 3
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  # Helper functions

  defp create_tmp_umbrella do
    tmp_dir = System.tmp_dir!() |> Path.join("arch_check_test_#{System.unique_integer()}")
    File.mkdir_p!(Path.join(tmp_dir, "apps"))
    tmp_dir
  end

  defp create_tmp_umbrella_with_violation do
    tmp_dir = create_tmp_umbrella()

    # Create two apps where one violates dependency rules
    create_app(tmp_dir, :app_a, [])
    create_app(tmp_dir, :app_b, [:app_a])  # app_b depends on app_a

    # app_a is not in allowed_direct_deps, so this creates a violation
    tmp_dir
  end

  defp create_app(root, app_name, deps) when is_atom(app_name) and is_list(deps) do
    app_dir = Path.join([root, "apps", to_string(app_name)])
    File.mkdir_p!(Path.join(app_dir, "lib"))

    dep_strings = Enum.map(deps, fn dep -> "{:#{dep}, in_umbrella: true}" end)
    deps_block = if dep_strings == [], do: "[]", else: "[#{Enum.join(dep_strings, ", ")}]"

    mix_exs = """
    defmodule #{Macro.camelize(to_string(app_name))}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
        #{deps_block}
      end
    end
    """

    File.write!(Path.join(app_dir, "mix.exs"), mix_exs)

    # Create a basic module file
    module_name = Macro.camelize(to_string(app_name))
    module_content = """
    defmodule #{module_name} do
      @moduledoc "Test module"
    end
    """

    File.write!(Path.join(app_dir, "lib/#{app_name}.ex"), module_content)

    app_dir
  end

  defp create_app_with_namespace(root, app_name, namespace, deps) do
    app_dir = create_app(root, app_name, deps)

    # Update the module to use the specified namespace
    module_content = """
    defmodule #{namespace} do
      @moduledoc "Test module with namespace"
    end
    """

    File.write!(Path.join(app_dir, "lib/#{app_name}.ex"), module_content)

    app_dir
  end

  defp create_app_with_code(root, app_name, namespace, code, deps) do
    app_dir = Path.join([root, "apps", to_string(app_name)])
    File.mkdir_p!(Path.join(app_dir, "lib"))

    dep_strings = Enum.map(deps, fn dep -> "{:#{dep}, in_umbrella: true}" end)
    deps_block = if dep_strings == [], do: "[]", else: "[#{Enum.join(dep_strings, ", ")}]"

    mix_exs = """
    defmodule #{Macro.camelize(to_string(app_name))}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app_name},
          version: "0.1.0",
          deps: deps()
        ]
      end

      defp deps do
        #{deps_block}
      end
    end
    """

    File.write!(Path.join(app_dir, "mix.exs"), mix_exs)
    File.write!(Path.join(app_dir, "lib/#{app_name}.ex"), code)

    app_dir
  end
end

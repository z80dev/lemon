defmodule LemonCore.Quality.ArchitectureDocsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureDocs

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "render_dependency_policy_markdown/1" do
    test "renders actual, allowed, and reference-only dependency columns" do
      assert ArchitectureDocs.render_dependency_policy_markdown(@repo_root) =~
               "| App | Actual direct deps from `mix.exs` | Allowed direct deps | Reference-only exceptions |"

      assert ArchitectureDocs.render_dependency_policy_markdown(@repo_root) =~
               "| `lemon_core` | *(none)* | *(none)* | *(none)* |"

      assert ArchitectureDocs.render_dependency_policy_markdown(@repo_root) =~
               "| `lemon_gateway` | `lemon_agent`, `lemon_core`, `lemon_media` | `lemon_agent`, `lemon_core`, `lemon_media` | `lemon_ai` |"
    end

    test "renders rows in sorted app order" do
      apps =
        ArchitectureDocs.render_dependency_policy_markdown(@repo_root)
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.map(fn row ->
          [_, app] = Regex.run(~r/^\| `([^`]+)` \|/, row)
          app
        end)

      assert apps == Enum.sort(apps)
    end
  end

  describe "package_map/1" do
    test "reads every umbrella app's version and Hex metadata from the repository" do
      packages = ArchitectureDocs.package_map(@repo_root)
      apps = @repo_root |> Path.join("apps/*/mix.exs") |> Path.wildcard()

      assert map_size(packages) == length(apps)
      assert Enum.all?(packages, fn {_app, %{version: v}} -> v =~ ~r/^\d+\.\d+\.\d+$/ end)
      assert packages.lemon_core.published?
      refute packages.lemon_router.published?

      assert ArchitectureDocs.render_package_map_markdown(@repo_root) =~
               "| `lemon_core` | #{packages.lemon_core.version} | yes |"
    end

    test "resolves @version, joins ++ lists and ignores nested package keys" do
      root = create_tmp_repo(["published"])

      try do
        write_mix(root, :published, """
        defmodule Published.MixProject do
          use Mix.Project
          @version "1.2.3"
          def project do
            [app: :published, version: @version, package: package()] ++ paths()
          end
          defp package, do: [licenses: ["MIT"]]
          defp paths, do: []
        end
        """)

        write_mix(root, :internal, """
        defmodule Internal.MixProject do
          use Mix.Project
          def project do
            [app: :internal, version: "0.1.0", docs: [package: :not_a_project_key]]
          end
        end
        """)

        write_mix(root, :computed, """
        defmodule Computed.MixProject do
          use Mix.Project
          def project, do: [app: :computed, version: version()]
          defp version, do: "9.9.9"
        end
        """)

        assert ArchitectureDocs.package_map(root) == %{
                 published: %{version: "1.2.3", published?: true},
                 internal: %{version: "0.1.0", published?: false},
                 computed: %{version: nil, published?: false}
               }

        assert ArchitectureDocs.render_package_map_markdown(root) ==
                 """
                 | App | Version in `mix.exs` | Hex publish set |
                 | --- | --- | --- |
                 | `computed` | *(not a literal)* | no |
                 | `internal` | 0.1.0 | no |
                 | `published` | 1.2.3 | yes |\
                 """
      after
        File.rm_rf!(root)
      end
    end
  end

  describe "replace_generated_sections/2" do
    test "replaces every section and is idempotent" do
      content = """
      # Architecture Boundaries

      <!-- architecture_policy:start -->
      stale
      <!-- architecture_policy:end -->

      <!-- package_map:start -->
      stale
      <!-- package_map:end -->
      """

      rendered = [architecture_policy: "policy \\1 table", package_map: "package table"]

      assert {:ok, once} = ArchitectureDocs.replace_generated_sections(content, rendered)
      assert once =~ "policy \\1 table"
      assert once =~ "package table"
      refute once =~ "stale"
      assert {:ok, ^once} = ArchitectureDocs.replace_generated_sections(once, rendered)
    end

    test "fails when a section's markers are missing" do
      content = "<!-- architecture_policy:start -->\nstale\n<!-- architecture_policy:end -->\n"

      assert {:error, %{code: :missing_architecture_doc_markers, message: message}} =
               ArchitectureDocs.replace_generated_sections(content,
                 architecture_policy: "policy",
                 package_map: "packages"
               )

      assert message =~ "<!-- package_map:start -->"
    end
  end

  describe "check/1" do
    test "reports stale architecture docs" do
      root = create_tmp_repo([])

      try do
        write_doc_fixture(root, "stale")

        assert {:error, report} = ArchitectureDocs.check(root)
        assert report.issue_count == 1
        assert [%{code: :stale_architecture_doc}] = report.issues
      after
        File.rm_rf!(root)
      end
    end

    test "passes when generated sections are current" do
      root = create_tmp_repo([])

      try do
        write_doc_fixture(root, "placeholder")

        :ok = ArchitectureDocs.write(root)
        assert {:ok, report} = ArchitectureDocs.check(root)
        assert report.issue_count == 0
      after
        File.rm_rf!(root)
      end
    end

    test "fails when the release package list and mix.exs Hex metadata disagree" do
      root = create_tmp_repo(["listed_only"])

      try do
        write_mix(root, :declared_only, """
        defmodule DeclaredOnly.MixProject do
          use Mix.Project
          def project, do: [app: :declared_only, version: "0.1.0", package: []]
        end
        """)

        write_doc_fixture(root, "placeholder")
        :ok = ArchitectureDocs.write(root)

        assert {:error, %{issues: [%{code: :package_set_mismatch, message: message}]}} =
                 ArchitectureDocs.check(root)

        assert message =~ "[:declared_only]"
        assert message =~ "[:listed_only]"
      after
        File.rm_rf!(root)
      end
    end

    test "fails closed when the release package list cannot be read" do
      root = create_tmp_repo([])

      try do
        File.rm!(Path.join(root, "scripts/verify_packages"))
        write_doc_fixture(root, "placeholder")
        :ok = ArchitectureDocs.write(root)

        assert {:error, %{issues: [%{code: :package_list_unreadable}]}} =
                 ArchitectureDocs.check(root)
      after
        File.rm_rf!(root)
      end
    end
  end

  defp create_tmp_repo(packages) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "architecture_docs_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.mkdir_p!(Path.join(tmp_dir, "scripts"))

    File.write!(
      Path.join(tmp_dir, "scripts/verify_packages"),
      "#!/usr/bin/env bash\nPACKAGES=(#{Enum.join(packages, " ")})\n"
    )

    tmp_dir
  end

  defp write_mix(root, app, source) do
    File.mkdir_p!(Path.join(root, "apps/#{app}"))
    File.write!(Path.join(root, "apps/#{app}/mix.exs"), source)
  end

  defp write_doc_fixture(root, body) do
    File.write!(Path.join(root, "docs/architecture_boundaries.md"), """
    # Architecture Boundaries

    ## Direct Dependency Policy

    <!-- architecture_policy:start -->
    #{body}
    <!-- architecture_policy:end -->

    ## Package Map

    <!-- package_map:start -->
    #{body}
    <!-- package_map:end -->
    """)
  end
end

defmodule LemonCore.Quality.ArchitectureDocsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.ArchitectureDocs

  describe "render_dependency_policy_markdown/0" do
    test "renders empty deps as none" do
      assert ArchitectureDocs.render_dependency_policy_markdown() =~
               "| `lemon_core` | *(none)* |"
    end

    test "renders rows in sorted app order" do
      apps =
        ArchitectureDocs.render_dependency_policy_markdown()
        |> String.split("\n", trim: true)
        |> Enum.drop(2)
        |> Enum.map(fn row ->
          [_, app, _deps] = Regex.run(~r/^\| `([^`]+)` \| (.+) \|$/, row)
          app
        end)

      assert apps == Enum.sort(apps)
    end
  end

  describe "replace_generated_section/2" do
    test "is idempotent" do
      content = """
      # Architecture Boundaries

      <!-- architecture_policy:start -->
      stale
      <!-- architecture_policy:end -->
      """

      assert {:ok, once} = ArchitectureDocs.replace_generated_section(content)
      assert {:ok, twice} = ArchitectureDocs.replace_generated_section(once)
      assert once == twice
    end
  end

  describe "check/1" do
    test "reports stale architecture docs" do
      tmp_dir = create_tmp_repo()

      try do
        write_doc_fixture(tmp_dir, """
        # Architecture Boundaries

        ## Direct Dependency Policy

        <!-- architecture_policy:start -->
        stale
        <!-- architecture_policy:end -->
        """)

        assert {:error, report} = ArchitectureDocs.check(tmp_dir)
        assert report.issue_count == 1
        assert [%{code: :stale_architecture_doc}] = report.issues
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes when generated section is current" do
      tmp_dir = create_tmp_repo()

      try do
        write_doc_fixture(tmp_dir, """
        # Architecture Boundaries

        ## Direct Dependency Policy

        <!-- architecture_policy:start -->
        placeholder
        <!-- architecture_policy:end -->
        """)

        :ok = ArchitectureDocs.write(tmp_dir)
        assert {:ok, report} = ArchitectureDocs.check(tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  defp create_tmp_repo do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "architecture_docs_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    tmp_dir
  end

  defp write_doc_fixture(root, content) do
    File.write!(Path.join(root, "docs/architecture_boundaries.md"), content)
  end
end

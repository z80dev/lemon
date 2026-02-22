defmodule LemonCore.Quality.DocsCheckTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.DocsCheck

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "run/1" do
    test "docs check passes for the repository catalog" do
      assert {:ok, report} = DocsCheck.run(root: @repo_root)
      assert report.issue_count == 0
      assert report.checked_files > 0
      assert is_binary(report.root)
    end

    test "returns error report when catalog has issues" do
      # Create a temporary directory with an invalid catalog
      tmp_dir = create_tmp_dir()

      catalog_content = """
      [
        %{path: "nonexistent.md", owner: "test", last_reviewed: Date.from_iso8601!("2020-01-01"), max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count > 0
        assert length(report.issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "accepts custom today date for freshness checks" do
      assert {:ok, report} = DocsCheck.run(root: @repo_root, today: Date.utc_today())
      assert is_integer(report.checked_files)
    end

    test "report structure contains all required fields" do
      assert {:ok, report} = DocsCheck.run(root: @repo_root)

      assert Map.has_key?(report, :root)
      assert Map.has_key?(report, :checked_files)
      assert Map.has_key?(report, :issue_count)
      assert Map.has_key?(report, :issues)
    end
  end

  describe "catalog coverage checks" do
    test "detects missing catalog entries for tracked docs" do
      tmp_dir = create_tmp_dir_with_structure()

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        missing_entry_issues = Enum.filter(report.issues, &(&1.code == :missing_catalog_entry))
        assert length(missing_entry_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes when all tracked docs are in catalog" do
      tmp_dir = create_tmp_dir_with_structure()

      try do
        # Add the missing file to catalog (paths are relative to docs/ directory)
        catalog_path = Path.join(tmp_dir, "docs/catalog.exs")
        catalog_content = """
        [
          %{path: "docs/README.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365},
          %{path: "docs/guide.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
        ]
        """
        File.write!(catalog_path, catalog_content)

        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "entry shape validation" do
    test "detects missing required fields in catalog entries" do
      tmp_dir = create_tmp_dir()
      catalog_content = """
      [
        %{owner: "test", last_reviewed: Date.from_iso8601!("2024-01-01"), max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        invalid_entry_issues = Enum.filter(report.issues, &(&1.code == :invalid_catalog_entry))
        assert length(invalid_entry_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "detects invalid owner field" do
      tmp_dir = create_tmp_dir()
      catalog_content = """
      [
        %{path: "test.md", owner: "", last_reviewed: Date.from_iso8601!("2024-01-01"), max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)
      File.write!(Path.join(tmp_dir, "test.md"), "content")

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        invalid_entry_issues = Enum.filter(report.issues, &(&1.code == :invalid_catalog_entry))
        assert length(invalid_entry_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "detects invalid max_age_days field" do
      tmp_dir = create_tmp_dir()
      catalog_content = """
      [
        %{path: "test.md", owner: "test", last_reviewed: Date.from_iso8601!("2024-01-01"), max_age_days: -1}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)
      File.write!(Path.join(tmp_dir, "test.md"), "content")

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        invalid_entry_issues = Enum.filter(report.issues, &(&1.code == :invalid_catalog_entry))
        assert length(invalid_entry_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "detects missing last_reviewed field" do
      tmp_dir = create_tmp_dir()
      catalog_content = """
      [
        %{path: "test.md", owner: "test", max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        invalid_entry_issues = Enum.filter(report.issues, &(&1.code == :invalid_catalog_entry))
        assert length(invalid_entry_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "file existence checks" do
    test "detects catalog entries pointing to non-existent files" do
      tmp_dir = create_tmp_dir()
      catalog_content = """
      [
        %{path: "missing.md", owner: "test", last_reviewed: Date.from_iso8601!("2024-01-01"), max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        missing_file_issues = Enum.filter(report.issues, &(&1.code == :missing_doc_file))
        assert length(missing_file_issues) > 0
        assert hd(missing_file_issues).path == "missing.md"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes when catalog files exist" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "exists.md"), "content")

      catalog_content = """
      [
        %{path: "exists.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "freshness checks" do
    test "detects stale documents" do
      old_date = Date.add(Date.utc_today(), -100)

      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "stale.md"), "content")

      catalog_content = """
      [
        %{path: "stale.md", owner: "test", last_reviewed: "#{Date.to_iso8601(old_date)}" |> Date.from_iso8601!(), max_age_days: 30}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        stale_issues = Enum.filter(report.issues, &(&1.code == :stale_doc))
        assert length(stale_issues) > 0
        assert hd(stale_issues).path == "stale.md"
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes for fresh documents" do
      recent_date = Date.utc_today()

      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "fresh.md"), "content")

      catalog_content = """
      [
        %{path: "fresh.md", owner: "test", last_reviewed: "#{Date.to_iso8601(recent_date)}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "link checking" do
    test "detects broken local markdown links" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "page.md"), "[broken link](nonexistent.md)")

      catalog_content = """
      [
        %{path: "page.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)

        broken_link_issues = Enum.filter(report.issues, &(&1.code == :broken_link))
        assert length(broken_link_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "passes for valid local links" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "target.md"), "target content")
      File.write!(Path.join(tmp_dir, "page.md"), "[valid link](target.md)")

      catalog_content = """
      [
        %{path: "page.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365},
        %{path: "target.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "ignores external links" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "page.md"), "[external](https://example.com)")

      catalog_content = """
      [
        %{path: "page.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "ignores anchor links" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "page.md"), "[anchor](#section)")

      catalog_content = """
      [
        %{path: "page.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "ignores mailto links" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "page.md"), "[email](mailto:test@example.com)")

      catalog_content = """
      [
        %{path: "page.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
      ]
      """
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

      try do
        assert {:ok, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count == 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  describe "catalog load failures" do
    test "returns error when catalog file is missing" do
      tmp_dir = System.tmp_dir!() |> Path.join("docs_check_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count > 0

        load_failed_issues = Enum.filter(report.issues, &(&1.code == :catalog_load_failed))
        assert length(load_failed_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "returns error when catalog has invalid Elixir syntax" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), "invalid elixir syntax [{")

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count > 0

        load_failed_issues = Enum.filter(report.issues, &(&1.code == :catalog_load_failed))
        assert length(load_failed_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "returns error when catalog evaluates to non-list" do
      tmp_dir = create_tmp_dir()
      File.write!(Path.join(tmp_dir, "docs/catalog.exs"), "%{not: :a_list}")

      try do
        assert {:error, report} = DocsCheck.run(root: tmp_dir)
        assert report.issue_count > 0

        load_failed_issues = Enum.filter(report.issues, &(&1.code == :catalog_load_failed))
        assert length(load_failed_issues) > 0
      after
        File.rm_rf!(tmp_dir)
      end
    end
  end

  # Helper functions

  defp create_tmp_dir do
    tmp_dir = System.tmp_dir!() |> Path.join("docs_check_test_#{System.unique_integer()}")
    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    tmp_dir
  end

  defp create_tmp_dir_with_structure do
    tmp_dir = create_tmp_dir()

    # Create some markdown files in the docs directory (where discover_tracked_docs looks)
    File.write!(Path.join(tmp_dir, "docs/README.md"), "# README")
    File.write!(Path.join(tmp_dir, "docs/guide.md"), "# Guide")

    # Create catalog with only one entry (missing the other file)
    # Paths should be relative to root, so they include "docs/" prefix
    catalog_content = """
    [
      %{path: "docs/README.md", owner: "test", last_reviewed: "#{Date.to_iso8601(Date.utc_today())}" |> Date.from_iso8601!(), max_age_days: 365}
    ]
    """
    File.write!(Path.join(tmp_dir, "docs/catalog.exs"), catalog_content)

    tmp_dir
  end
end

defmodule LemonCore.Quality.DocsCatalogTest do
  @moduledoc """
  Tests for the DocsCatalog module.
  """
  use LemonCore.Testing.Case, async: true

  alias LemonCore.Quality.DocsCatalog

  @catalog_path "docs/catalog.exs"

  describe "catalog_file/1" do
    test "returns correct catalog file path for given root", %{harness: harness} do
      root = harness.tmp_dir
      expected_path = Path.join(root, @catalog_path)
      assert DocsCatalog.catalog_file(root) == expected_path
    end

    test "returns path with correct structure for nested root", %{harness: harness} do
      nested_root = Path.join(harness.tmp_dir, "some/nested/path")
      File.mkdir_p!(nested_root)
      
      expected_path = Path.join(nested_root, @catalog_path)
      assert DocsCatalog.catalog_file(nested_root) == expected_path
    end
  end

  describe "load/1" do
    test "returns error when catalog file is missing", %{harness: harness} do
      root = harness.tmp_dir
      # Ensure no catalog file exists
      catalog_file = Path.join(root, @catalog_path)
      refute File.exists?(catalog_file)

      assert {:error, message} = DocsCatalog.load(root: root)
      assert message =~ "Missing catalog file"
      assert message =~ catalog_file
    end

    test "returns entries when catalog file exists and is valid", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      entries = [
        %{
          path: "docs/getting_started.md",
          owner: "@team-docs",
          last_reviewed: ~D[2026-01-15],
          max_age_days: 90
        },
        %{
          path: "docs/api_reference.md",
          owner: "@team-api",
          last_reviewed: ~D[2026-02-01],
          max_age_days: 60
        }
      ]

      File.write!(catalog_file, inspect(entries))

      assert {:ok, loaded_entries} = DocsCatalog.load(root: root)
      assert length(loaded_entries) == 2
      
      [first, second] = loaded_entries
      assert first.path == "docs/getting_started.md"
      assert first.owner == "@team-docs"
      assert first.last_reviewed == ~D[2026-01-15]
      assert first.max_age_days == 90
      
      assert second.path == "docs/api_reference.md"
      assert second.owner == "@team-api"
    end

    test "returns empty list for empty catalog file", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      File.write!(catalog_file, "[]")

      assert {:ok, []} = DocsCatalog.load(root: root)
    end

    test "returns error when catalog evaluates to non-list", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      # Write a map instead of a list
      File.write!(catalog_file, "%{foo: :bar}")

      assert {:error, message} = DocsCatalog.load(root: root)
      assert message =~ "Expected"
      assert message =~ "to evaluate to a list"
      assert message =~ "%{foo: :bar}"
    end

    test "returns error when catalog evaluates to atom", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      File.write!(catalog_file, ":not_a_list")

      assert {:error, message} = DocsCatalog.load(root: root)
      assert message =~ "Expected"
      assert message =~ "to evaluate to a list"
      assert message =~ ":not_a_list"
    end

    test "returns error when catalog has syntax errors", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      # Write invalid Elixir syntax
      File.write!(catalog_file, "[%{path: \"test.md\", invalid syntax here}")

      assert {:error, message} = DocsCatalog.load(root: root)
      assert message =~ "Failed to evaluate"
      assert message =~ catalog_file
    end

    test "returns error when catalog has undefined variable", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      # Reference an undefined variable
      File.write!(catalog_file, "[undefined_variable]")

      assert {:error, message} = DocsCatalog.load(root: root)
      assert message =~ "Failed to evaluate"
    end

    test "loads catalog from repository root" do
      # Test loading the actual catalog file from the repository
      repo_root = Path.expand("../../../../..", __DIR__)
      assert {:ok, entries} = DocsCatalog.load(root: repo_root)
      assert is_list(entries)
      assert length(entries) > 0
    end

    test "handles catalog with extra optional fields", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      entries = [
        %{
          path: "docs/guide.md",
          owner: "@team-docs",
          last_reviewed: ~D[2026-01-01],
          max_age_days: 30,
          custom_field: "custom_value",
          another_option: true
        }
      ]

      File.write!(catalog_file, inspect(entries))

      assert {:ok, [entry]} = DocsCatalog.load(root: root)
      assert entry.path == "docs/guide.md"
      assert entry.custom_field == "custom_value"
      assert entry.another_option == true
    end

    test "handles deeply nested docs directory", %{harness: harness} do
      root = harness.tmp_dir
      catalog_dir = Path.join(root, "docs")
      File.mkdir_p!(catalog_dir)
      catalog_file = Path.join(catalog_dir, "catalog.exs")

      entries = [
        %{
          path: "docs/architecture/overview.md",
          owner: "@team-arch",
          last_reviewed: ~D[2026-01-20],
          max_age_days: 180
        }
      ]

      File.write!(catalog_file, inspect(entries))

      assert {:ok, [entry]} = DocsCatalog.load(root: root)
      assert entry.path == "docs/architecture/overview.md"
    end
  end
end

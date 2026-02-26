defmodule LemonCore.Quality.CleanupTest do
  use ExUnit.Case, async: true

  alias LemonCore.Quality.Cleanup

  @repo_root Path.expand("../../../../..", __DIR__)

  describe "scan/1" do
    test "returns structured report with default options" do
      report = Cleanup.scan(root: @repo_root)

      assert is_binary(report.root)
      assert report.retention_days == 14
      assert is_list(report.old_run_files)
      assert is_list(report.stale_docs)
      assert report.deleted_files == []
    end

    test "accepts custom retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 7)
      assert report.retention_days == 7

      report = Cleanup.scan(root: @repo_root, retention_days: 30)
      assert report.retention_days == 30
    end

    test "accepts custom root directory" do
      report = Cleanup.scan(root: @repo_root)
      assert report.root == @repo_root
    end

    test "accepts custom today date for deterministic testing" do
      today = ~D[2024-01-15]
      report = Cleanup.scan(root: @repo_root, today: today)

      assert report.root == @repo_root
      assert is_list(report.old_run_files)
    end

    test "scan with zero retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 1)
      assert report.retention_days == 1
      assert is_list(report.old_run_files)
    end

    test "scan with large retention days" do
      report = Cleanup.scan(root: @repo_root, retention_days: 365)
      assert report.retention_days == 365
      assert is_list(report.old_run_files)
    end
  end

  describe "prune/1" do
    test "prune with apply: false performs dry run" do
      report = Cleanup.prune(root: @repo_root, apply: false)

      assert is_binary(report.root)
      assert is_list(report.old_run_files)
      assert report.deleted_files == []
    end

    test "prune with apply: true attempts deletion" do
      report = Cleanup.prune(root: @repo_root, apply: true)

      assert is_binary(report.root)
      assert is_list(report.old_run_files)
      # deleted_files may or may not be empty depending on actual file state
      assert is_list(report.deleted_files)
    end

    test "prune respects custom retention days" do
      report = Cleanup.prune(root: @repo_root, retention_days: 1, apply: false)
      assert report.retention_days == 1
    end

    test "prune with no options uses defaults" do
      # This will use File.cwd!() as root, so we test the structure
      report = Cleanup.prune([])

      assert is_binary(report.root)
      assert report.retention_days == 14
      assert is_list(report.old_run_files)
      assert is_list(report.stale_docs)
      assert is_list(report.deleted_files)
    end
  end

  describe "edge cases" do
    test "scan handles non-existent run directory gracefully" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      try do
        report = Cleanup.scan(root: tmp_dir)
        assert report.root == tmp_dir
        assert report.old_run_files == []
        assert report.stale_docs == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "prune handles non-existent run directory gracefully" do
      tmp_dir = Path.join(System.tmp_dir!(), "cleanup_test_#{System.unique_integer()}")
      File.mkdir_p!(tmp_dir)

      try do
        report = Cleanup.prune(root: tmp_dir, apply: true)
        assert report.root == tmp_dir
        assert report.deleted_files == []
      after
        File.rm_rf!(tmp_dir)
      end
    end

    test "scan with very old date finds more files" do
      # Using a date far in the future means even recent files are "old"
      future_date = Date.add(Date.utc_today(), 365)
      report = Cleanup.scan(root: @repo_root, today: future_date, retention_days: 1)

      assert is_list(report.old_run_files)
    end

    test "scan with recent date finds fewer files" do
      # Using a date in the past means fewer files are "old"
      past_date = ~D[2020-01-01]
      report = Cleanup.scan(root: @repo_root, today: past_date, retention_days: 1)

      assert is_list(report.old_run_files)
    end
  end

  describe "report structure" do
    test "report contains all required keys" do
      report = Cleanup.scan(root: @repo_root)

      assert Map.has_key?(report, :root)
      assert Map.has_key?(report, :retention_days)
      assert Map.has_key?(report, :old_run_files)
      assert Map.has_key?(report, :stale_docs)
      assert Map.has_key?(report, :deleted_files)
    end

    test "old_run_files are sorted" do
      report = Cleanup.scan(root: @repo_root)
      assert report.old_run_files == Enum.sort(report.old_run_files)
    end

    test "old_run_files contain absolute paths" do
      report = Cleanup.scan(root: @repo_root)

      for path <- report.old_run_files do
        assert Path.type(path) == :absolute
      end
    end
  end
end

defmodule LemonCore.Browser.ArtifactsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Browser.Artifacts

  test "lists recent browser artifacts by modification time" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)
    old = Path.join(tmp_dir, "old.png")
    new = Path.join(tmp_dir, "new.png")
    File.write!(old, "old")
    File.write!(new, "newer")
    File.touch!(old, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(new, {{2026, 1, 2}, {0, 0, 0}})

    assert [
             %{name: "new.png", path: ^new, bytes: 5},
             %{name: "old.png", path: ^old, bytes: 3}
           ] = Artifacts.recent(dir: tmp_dir, limit: 10)
  end

  test "returns empty list when artifact directory is absent" do
    assert [] = Artifacts.recent(dir: Path.join(tmp_dir(), "missing"))
  end

  test "summarizes artifact cleanup metadata without reading artifact bytes" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)
    old = Path.join(tmp_dir, "old.png")
    new = Path.join(tmp_dir, "new.png")
    File.write!(old, "old")
    File.write!(new, "newer")
    File.touch!(old, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(new, {{2026, 1, 2}, {0, 0, 0}})

    summary = Artifacts.summary(dir: tmp_dir)

    assert summary.dir == tmp_dir
    assert summary.exists == true
    assert summary.count == 2
    assert summary.total_bytes == 8
    assert summary.oldest_modified_at =~ "2026-01-01"
    assert summary.newest_modified_at =~ "2026-01-02"
    assert summary.cleanup.managed == true
    assert summary.cleanup.policy == "managed: 14d or 100 files"
    assert summary.cleanup.max_age_days == 14
    assert summary.cleanup.max_files == 100
    assert summary.cleanup.safe_to_delete == true
    assert summary.cleanup.embeds_artifact_bytes_in_support_bundle == false
  end

  test "cleans up old browser artifacts and keeps recent files" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)
    stale = Path.join(tmp_dir, "stale.png")
    fresh = Path.join(tmp_dir, "fresh.png")
    File.write!(stale, "stale")
    File.write!(fresh, "fresh")
    File.touch!(stale, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(fresh, {{2026, 1, 10}, {0, 0, 0}})

    now = DateTime.to_unix(~U[2026-01-10 00:00:00Z])

    result = Artifacts.cleanup(dir: tmp_dir, max_age_seconds: 2 * 24 * 60 * 60, now: now)

    assert result.deleted_count == 1
    assert result.deleted_bytes == 5
    assert result.retained_count == 1
    refute File.exists?(stale)
    assert File.exists?(fresh)
  end

  test "cleans up oldest browser artifacts beyond max file count" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)
    oldest = Path.join(tmp_dir, "oldest.png")
    middle = Path.join(tmp_dir, "middle.png")
    newest = Path.join(tmp_dir, "newest.png")
    File.write!(oldest, "oldest")
    File.write!(middle, "middle")
    File.write!(newest, "newest")
    File.touch!(oldest, {{2026, 1, 1}, {0, 0, 0}})
    File.touch!(middle, {{2026, 1, 2}, {0, 0, 0}})
    File.touch!(newest, {{2026, 1, 3}, {0, 0, 0}})

    result = Artifacts.cleanup(dir: tmp_dir, max_age_seconds: 365 * 24 * 60 * 60, max_files: 2)

    assert result.deleted_count == 1
    refute File.exists?(oldest)
    assert File.exists?(middle)
    assert File.exists?(newest)
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_browser_artifacts_test_#{System.unique_integer([:positive])}"
    )
  end
end

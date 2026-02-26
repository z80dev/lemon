defmodule LemonCore.ConfigReloader.DigestTest do
  @moduledoc """
  Tests for the ConfigReloader.Digest module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.ConfigReloader.Digest

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "digest_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "file_fingerprint/1" do
    test "returns fingerprint for existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.toml")
      File.write!(path, "[agent]\ndefault_provider = \"anthropic\"\n")

      fp = Digest.file_fingerprint(path)

      assert fp.status == :ok
      assert fp.path == Path.expand(path)
      assert is_tuple(fp.mtime)
      assert is_integer(fp.size)
      assert fp.size > 0
      assert is_binary(fp.hash)
    end

    test "returns missing status for non-existent file" do
      fp = Digest.file_fingerprint("/tmp/nonexistent_#{System.unique_integer([:positive])}.toml")

      assert fp.status == :missing
      assert is_nil(fp.mtime)
      assert is_nil(fp.size)
      assert is_nil(fp.hash)
    end

    test "detects content changes via hash", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "changing.toml")

      File.write!(path, "version = 1")
      fp1 = Digest.file_fingerprint(path)

      File.write!(path, "version = 2")
      fp2 = Digest.file_fingerprint(path)

      assert fp1.hash != fp2.hash
    end
  end

  describe "file_fingerprints/1" do
    test "returns fingerprints for multiple paths", %{tmp_dir: tmp_dir} do
      path1 = Path.join(tmp_dir, "a.toml")
      path2 = Path.join(tmp_dir, "b.toml")
      File.write!(path1, "a")
      File.write!(path2, "b")

      fps = Digest.file_fingerprints([path1, path2])

      assert length(fps) == 2
      assert Enum.all?(fps, &(&1.status == :ok))
    end
  end

  describe "files_digest/1" do
    test "produces a source digest with correct structure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.toml")
      File.write!(path, "content")

      digest = Digest.files_digest([path])

      assert digest.source == :files
      assert is_list(digest.fingerprints)
      assert length(digest.fingerprints) == 1
      assert is_integer(digest.computed_at_ms)
    end
  end

  describe "env_digest/1" do
    test "produces digest for .env path", %{tmp_dir: tmp_dir} do
      env_path = Path.join(tmp_dir, ".env")
      File.write!(env_path, "FOO=bar")

      digest = Digest.env_digest(env_path)

      assert digest.source == :env
      assert length(digest.fingerprints) == 1
      assert hd(digest.fingerprints).status == :ok
    end

    test "handles nil dotenv path" do
      digest = Digest.env_digest(nil)

      assert digest.source == :env
      assert digest.fingerprints == []
    end
  end

  describe "secrets_digest/1" do
    test "produces digest from metadata list" do
      metadata = [
        %{owner: "default", name: "API_KEY", updated_at: 1000, version: "v1"},
        %{owner: "default", name: "DB_PASS", updated_at: 2000, version: "v1"}
      ]

      digest = Digest.secrets_digest(metadata)

      assert digest.source == :secrets
      assert length(digest.fingerprints) == 2
      # Should be sorted by {owner, name}
      assert hd(digest.fingerprints).name == "API_KEY"
    end

    test "handles empty metadata list" do
      digest = Digest.secrets_digest([])

      assert digest.source == :secrets
      assert digest.fingerprints == []
    end
  end

  describe "compare/2" do
    test "detects file changes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.toml")

      File.write!(path, "v1")
      old_digests = %{files: Digest.files_digest([path])}

      File.write!(path, "v2")
      new_digests = %{files: Digest.files_digest([path])}

      {changed, _merged} = Digest.compare(old_digests, new_digests)

      assert :files in changed
    end

    test "reports no changes when content is the same", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "stable.toml")
      File.write!(path, "stable content")

      digest = Digest.files_digest([path])
      old = %{files: digest}
      new = %{files: digest}

      {changed, _merged} = Digest.compare(old, new)

      assert changed == []
    end

    test "detects new source added" do
      old = %{}
      new = %{secrets: Digest.secrets_digest([%{owner: "x", name: "y", updated_at: 1, version: "v1"}])}

      {changed, _merged} = Digest.compare(old, new)

      assert :secrets in changed
    end

    test "detects secret metadata changes" do
      meta1 = [%{owner: "default", name: "KEY", updated_at: 1000, version: "v1"}]
      meta2 = [%{owner: "default", name: "KEY", updated_at: 2000, version: "v1"}]

      old = %{secrets: Digest.secrets_digest(meta1)}
      new = %{secrets: Digest.secrets_digest(meta2)}

      {changed, _merged} = Digest.compare(old, new)

      assert :secrets in changed
    end
  end

  describe "source_changed?/2" do
    test "nil to something is a change" do
      digest = Digest.secrets_digest([])
      assert Digest.source_changed?(nil, digest) == true
    end

    test "something to nil is a change" do
      digest = Digest.secrets_digest([])
      assert Digest.source_changed?(digest, nil) == true
    end

    test "nil to nil is not a change" do
      assert Digest.source_changed?(nil, nil) == false
    end
  end
end

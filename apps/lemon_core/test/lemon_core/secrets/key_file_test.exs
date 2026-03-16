defmodule LemonCore.Secrets.KeyFileTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.KeyFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_key_file_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    key_path = Path.join(tmp_dir, "master.key")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, key_path: key_path, tmp_dir: tmp_dir}
  end

  describe "available?/0" do
    test "always returns true" do
      assert KeyFile.available?()
    end
  end

  describe "put_master_key/2" do
    test "writes key to file", %{key_path: path} do
      assert :ok = KeyFile.put_master_key("my-key-value", key_file_path: path)
      assert File.read!(path) == "my-key-value"
    end

    test "sets file permissions to 0600", %{key_path: path} do
      :ok = KeyFile.put_master_key("secret", key_file_path: path)
      {:ok, stat} = File.stat(path)
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end

    test "creates parent directories", %{tmp_dir: tmp} do
      nested = Path.join([tmp, "deep", "nested", "master.key"])
      assert :ok = KeyFile.put_master_key("nested-key", key_file_path: nested)
      assert File.read!(nested) == "nested-key"
    end

    test "returns {:error, :invalid_value} for non-binary" do
      assert {:error, :invalid_value} = KeyFile.put_master_key(12345, [])
    end

    test "overwrites existing key", %{key_path: path} do
      :ok = KeyFile.put_master_key("first", key_file_path: path)
      :ok = KeyFile.put_master_key("second", key_file_path: path)
      assert File.read!(path) == "second"
    end
  end

  describe "get_master_key/1" do
    test "returns {:ok, value} when file exists", %{key_path: path} do
      File.write!(path, "stored-key")
      assert {:ok, "stored-key"} = KeyFile.get_master_key(key_file_path: path)
    end

    test "trims whitespace", %{key_path: path} do
      File.write!(path, "  stored-key  \n")
      assert {:ok, "stored-key"} = KeyFile.get_master_key(key_file_path: path)
    end

    test "returns {:error, :missing} when file does not exist", %{tmp_dir: tmp} do
      assert {:error, :missing} =
               KeyFile.get_master_key(key_file_path: Path.join(tmp, "nope"))
    end

    test "returns {:error, :missing} for empty file", %{key_path: path} do
      File.write!(path, "")
      assert {:error, :missing} = KeyFile.get_master_key(key_file_path: path)
    end

    test "returns {:error, :missing} for whitespace-only file", %{key_path: path} do
      File.write!(path, "   \n  ")
      assert {:error, :missing} = KeyFile.get_master_key(key_file_path: path)
    end
  end

  describe "delete_master_key/1" do
    test "removes the key file", %{key_path: path} do
      File.write!(path, "doomed")
      assert :ok = KeyFile.delete_master_key(key_file_path: path)
      refute File.exists?(path)
    end

    test "returns {:error, :missing} when file does not exist", %{tmp_dir: tmp} do
      assert {:error, :missing} =
               KeyFile.delete_master_key(key_file_path: Path.join(tmp, "nope"))
    end
  end

  describe "key_file_path/1" do
    test "defaults to ~/.lemon/master.key" do
      expected = Path.join(System.user_home!(), ".lemon/master.key")
      assert KeyFile.key_file_path() == expected
    end

    test "respects :key_file_path option" do
      assert KeyFile.key_file_path(key_file_path: "/custom/path") == "/custom/path"
    end
  end

  describe "full lifecycle" do
    test "put, get, delete round-trip", %{key_path: path} do
      assert {:error, :missing} = KeyFile.get_master_key(key_file_path: path)
      assert :ok = KeyFile.put_master_key("lifecycle-key", key_file_path: path)
      assert {:ok, "lifecycle-key"} = KeyFile.get_master_key(key_file_path: path)
      assert :ok = KeyFile.delete_master_key(key_file_path: path)
      assert {:error, :missing} = KeyFile.get_master_key(key_file_path: path)
    end
  end
end

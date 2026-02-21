defmodule LemonCore.DotenvTest do
  use ExUnit.Case, async: false

  alias LemonCore.Dotenv

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "lemon_dotenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    tracked_keys = [
      "DOTENV_SIMPLE",
      "DOTENV_SPACED",
      "DOTENV_QUOTED",
      "DOTENV_SINGLE",
      "DOTENV_COMMENTED",
      "DOTENV_EXISTING",
      "DOTENV_EMPTY",
      "DOTENV_ESCAPE_N",
      "DOTENV_ESCAPE_T",
      "DOTENV_ESCAPE_QUOTE"
    ]

    previous =
      Enum.into(tracked_keys, %{}, fn key ->
        {key, System.get_env(key)}
      end)

    Enum.each(tracked_keys, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "load/2" do
    test "loads variables from .env", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      DOTENV_SIMPLE=hello
      DOTENV_SPACED = world
      DOTENV_QUOTED="hello there"
      DOTENV_SINGLE='single value'
      DOTENV_COMMENTED=abc # trailing comment
      """)

      assert :ok = Dotenv.load(tmp_dir)

      assert System.get_env("DOTENV_SIMPLE") == "hello"
      assert System.get_env("DOTENV_SPACED") == "world"
      assert System.get_env("DOTENV_QUOTED") == "hello there"
      assert System.get_env("DOTENV_SINGLE") == "single value"
      assert System.get_env("DOTENV_COMMENTED") == "abc"
    end

    test "supports export prefix and does not override existing values by default", %{
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, ".env"), """
      export DOTENV_SIMPLE=from_export
      DOTENV_EXISTING=from_env_file
      """)

      System.put_env("DOTENV_EXISTING", "already-set")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "from_export"
      assert System.get_env("DOTENV_EXISTING") == "already-set"
    end

    test "returns :ok when .env file is missing", %{tmp_dir: tmp_dir} do
      assert :ok = Dotenv.load(tmp_dir)
    end

    test "can override existing values when override: true", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_EXISTING=from_file\n")
      System.put_env("DOTENV_EXISTING", "already-set")

      assert :ok = Dotenv.load(tmp_dir, override: true)
      assert System.get_env("DOTENV_EXISTING") == "from_file"
    end

    test "handles empty values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_EMPTY=\n")

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_EMPTY") == ""
    end

    test "skips blank lines and comments", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """

      # This is a comment
      DOTENV_SIMPLE=value

      # Another comment
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "value"
    end

    test "handles escape sequences in double-quoted values", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), ~S"""
      DOTENV_ESCAPE_N="line1\nline2"
      DOTENV_ESCAPE_T="col1\tcol2"
      DOTENV_ESCAPE_QUOTE="say \"hello\""
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_ESCAPE_N") == "line1\nline2"
      assert System.get_env("DOTENV_ESCAPE_T") == "col1\tcol2"
      assert System.get_env("DOTENV_ESCAPE_QUOTE") == "say \"hello\""
    end

    test "skips lines with invalid key names", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), """
      123INVALID=nope
      DOTENV_SIMPLE=valid
      """)

      assert :ok = Dotenv.load(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "valid"
    end
  end

  describe "path_for/1" do
    test "returns .env in current directory for nil" do
      assert Dotenv.path_for(nil) == Path.join(File.cwd!(), ".env")
    end

    test "returns .env in current directory for empty string" do
      assert Dotenv.path_for("") == Path.join(File.cwd!(), ".env")
    end

    test "returns .env in specified directory" do
      assert Dotenv.path_for("/custom/path") == "/custom/path/.env"
    end

    test "expands relative paths" do
      result = Dotenv.path_for("~/some/dir")
      refute String.starts_with?(result, "~")
      assert String.ends_with?(result, ".env")
    end
  end

  describe "load_and_log/2" do
    test "returns :ok when file is missing", %{tmp_dir: tmp_dir} do
      assert :ok = Dotenv.load_and_log(tmp_dir)
    end

    test "returns :ok and loads variables from .env", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".env"), "DOTENV_SIMPLE=logged\n")

      assert :ok = Dotenv.load_and_log(tmp_dir)
      assert System.get_env("DOTENV_SIMPLE") == "logged"
    end
  end
end

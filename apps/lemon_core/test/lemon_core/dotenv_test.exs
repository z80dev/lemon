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
      "DOTENV_EXISTING"
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
end

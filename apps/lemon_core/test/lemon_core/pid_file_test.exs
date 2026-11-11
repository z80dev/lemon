defmodule LemonCore.PidFileTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "records bind a live PID to its birth time", %{tmp_dir: dir} do
    path = Path.join(dir, "owner")
    assert :ok = LemonCore.PidFile.write(path)
    assert LemonCore.PidFile.live?(path)
    assert String.starts_with?(File.read!(path), System.pid() <> "\n")
    File.write!(path, System.pid() <> "\nnot this process")
    refute LemonCore.PidFile.live?(path)
    File.write!(path, "invalid")
    refute LemonCore.PidFile.live?(path)
    File.rm!(path)
    refute LemonCore.PidFile.live?(path)
  end
end

defmodule CodingAgent.ExecutionNode.PythonTest do
  # Resolution caches the Command Line Tools probe in :persistent_term, which is
  # global state; this module therefore runs serially and restores the cache.
  use ExUnit.Case, async: false
  alias CodingAgent.ExecutionNode.Python

  @moduletag :tmp_dir

  defp bundle(root, mode) do
    bin = Path.join([root, "python", "bin"])
    File.mkdir_p!(bin)
    path = Path.join(bin, "python3")
    File.write!(path, "#!/bin/sh\nexit 0\n")
    File.chmod!(path, mode)
    path
  end

  defp never_called(name) do
    raise "PATH lookup for #{name} must not happen when the release bundles an interpreter"
  end

  test "the bundled interpreter wins over anything on PATH", %{tmp_dir: tmp_dir} do
    bundled = bundle(tmp_dir, 0o755)

    assert {:ok, ^bundled} =
             Python.executable(root: tmp_dir, find_executable: &never_called/1)
  end

  test "a non-executable or missing bundle falls through to PATH", %{tmp_dir: tmp_dir} do
    assert {:error, :not_installed} =
             Python.executable(root: tmp_dir, find_executable: fn _ -> nil end)

    bundle(tmp_dir, 0o644)

    assert {:ok, "/opt/python3"} =
             Python.executable(root: tmp_dir, find_executable: fn "python3" -> "/opt/python3" end)

    directory = Path.join([tmp_dir, "dir-bundle", "python", "bin", "python3"])
    File.mkdir_p!(directory)

    assert {:ok, "/opt/python3"} =
             Python.executable(
               root: Path.join(tmp_dir, "dir-bundle"),
               find_executable: fn "python3" -> "/opt/python3" end
             )
  end

  test "darwin accepts Apple's shim only with Command Line Tools", %{tmp_dir: tmp_dir} do
    shim = fn _ -> "/usr/bin/python3" end

    assert {:error, :not_installed} =
             Python.executable(
               root: tmp_dir,
               find_executable: shim,
               os_type: {:unix, :darwin},
               clt?: false
             )

    assert {:ok, "/usr/bin/python3"} =
             Python.executable(
               root: tmp_dir,
               find_executable: shim,
               os_type: {:unix, :darwin},
               clt?: true
             )

    # A non-Apple interpreter on darwin never consults xcode-select.
    assert {:ok, "/opt/homebrew/bin/python3"} =
             Python.executable(
               root: tmp_dir,
               find_executable: fn _ -> "/opt/homebrew/bin/python3" end,
               os_type: {:unix, :darwin},
               clt?: false
             )

    # Linux has no developer-tools shim, so the same path is fine there.
    assert {:ok, "/usr/bin/python3"} =
             Python.executable(
               root: tmp_dir,
               find_executable: shim,
               os_type: {:unix, :linux},
               clt?: false
             )
  end

  test "no bundle and no python3 on PATH is a clean not_installed", %{tmp_dir: tmp_dir} do
    assert {:error, :not_installed} =
             Python.executable(
               root: tmp_dir,
               find_executable: fn _ -> nil end,
               os_type: {:unix, :darwin}
             )

    assert {:error, :not_installed} =
             Python.executable(
               root: tmp_dir,
               find_executable: fn _ -> false end,
               os_type: {:unix, :linux}
             )
  end

  test "the Command Line Tools probe runs once and is cached", %{tmp_dir: tmp_dir} do
    on_exit(&Python.forget_command_line_tools/0)
    Python.forget_command_line_tools()

    opts = [
      root: tmp_dir,
      find_executable: fn _ -> "/usr/bin/python3" end,
      os_type: {:unix, :darwin}
    ]

    first = Python.executable(opts)

    assert first in [{:ok, "/usr/bin/python3"}, {:error, :not_installed}]
    assert is_boolean(:persistent_term.get({Python, :command_line_tools?}))
    assert Python.executable(opts) == first
  end

  test "the capability probe exposes the same resolution" do
    probe = CodingAgent.ExecutionNode.Capabilities.Probe.python()

    case Python.executable() do
      {:ok, path} -> assert probe == path
      {:error, :not_installed} -> assert probe == nil
    end
  end
end

defmodule LemonCore.BrowserProvider.CommandTest do
  use ExUnit.Case, async: false

  alias LemonCore.BrowserProvider.Command

  @moduletag :tmp_dir

  test "argv is literal, input is line-oriented, and environment overrides are scoped", %{
    tmp_dir: dir
  } do
    executable =
      script(
        dir,
        "echo arguments",
        "printf '%s\\n' \"$@\"\nIFS= read -r input\nprintf '%s\\n' \"$input\" \"$BROWSER_PROBE_ENV\"\n"
      )

    argument = "; touch " <> Path.join(dir, "must not exist")

    assert {:ok, output} =
             Command.run([executable, "browser", "status", argument],
               input: "{\"connected\":true}\n",
               env: %{"BROWSER_PROBE_ENV" => "only child"}
             )

    assert output == "browser\nstatus\n#{argument}\n{\"connected\":true}\nonly child\n"
    refute File.exists?(Path.join(dir, "must not exist"))
  end

  test "nonzero status output is private unless explicitly requested", %{tmp_dir: dir} do
    executable = script(dir, "nonzero", "printf 'private output'\nexit 7\n")
    assert {:error, :exit_nonzero} = Command.run([executable])

    assert {:ok, %{status: 7, output: "private output"}} =
             Command.run([executable], accept_nonzero: true)
  end

  test "missing, invalid, and non-executable commands fail closed", %{tmp_dir: dir} do
    path = Path.join(dir, "not executable")
    File.write!(path, "not executable")
    assert {:error, :binary_missing} = Command.run([path])
    assert {:error, :binary_missing} = Command.run([Path.join(dir, "missing")])
    assert {:error, :invalid_config} = Command.run([])
    assert {:error, :invalid_config} = Command.run(["sh", "bad\0argument"])
    assert {:error, :invalid_config} = Command.run(["sh"], timeout_ms: 0)
    assert {:error, :invalid_config} = Command.run(["sh"], env: %{"BAD=NAME" => "value"})
  end

  test "timeout kills the subprocess and its descendants", %{tmp_dir: dir} do
    {executable, pids} = waiting_script(dir, "timeout")
    assert {:error, :timeout} = Command.run([executable], timeout_ms: 2_000)
    assert_stopped(pids)
  end

  test "output overflow kills the subprocess and its descendants", %{tmp_dir: dir} do
    pids = Path.join(dir, "overflow.pids")

    executable =
      script(
        dir,
        "overflow",
        "sleep 60 &\nchild=$!\nprintf '%s\\n%s\\n' \"$$\" \"$child\" > #{shell_quote(pids)}\nwhile :; do printf 'bounded private output\\n'; done\n"
      )

    assert {:error, :output_too_large} =
             Command.run([executable], max_output_bytes: 100, timeout_ms: 1_000)

    assert_stopped(pids)
  end

  test "killing a resolver caller cannot orphan its command", %{tmp_dir: dir} do
    {executable, pids} = waiting_script(dir, "cancel")
    caller = spawn(fn -> Command.run([executable], timeout_ms: 5_000) end)
    assert eventually(fn -> File.exists?(pids) end)
    Process.exit(caller, :kill)
    assert_stopped(pids)
  end

  defp waiting_script(dir, name) do
    pids = Path.join(dir, name <> ".pids")

    executable =
      script(
        dir,
        name,
        "sleep 60 &\nchild=$!\nprintf '%s\\n%s\\n' \"$$\" \"$child\" > #{shell_quote(pids)}\nwait\n"
      )

    {executable, pids}
  end

  defp script(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  defp assert_stopped(path) do
    assert eventually(fn -> File.exists?(path) and File.read!(path) != "" end)
    pids = path |> File.read!() |> String.split("\n", trim: true)
    assert length(pids) == 2

    assert eventually(fn ->
             Enum.all?(pids, fn pid ->
               case System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true) do
                 {_, status} when status != 0 ->
                   true

                 {state, 0} ->
                   String.trim(state) == "" or String.starts_with?(String.trim(state), "Z")
               end
             end)
           end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

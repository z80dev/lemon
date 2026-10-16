defmodule CodingAgent.Tools.BashShellStateTest do
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.Bash
  alias CodingAgent.Tools.Bash.ShellState
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  defp run(ws, sid, params, owner_pid \\ self()) do
    tool = Bash.tool(ws, session_id: sid, session_pid: owner_pid)
    assert %AgentToolResult{} = result = tool.execute.("id", params, nil, nil)
    text = result.content |> Enum.map_join("", & &1.text)
    {text, result}
  end

  defp sid, do: "shell-state-#{System.unique_integer([:positive])}"

  test "cwd and env persist within a session, not across sessions", %{tmp_dir: ws} do
    File.mkdir_p!(Path.join(ws, "sub"))
    ws = File.cwd!() |> then(fn _ -> Path.expand(ws) end)
    a = sid()

    run(ws, a, %{"command" => "cd sub && export LEMON_SS_X=hello"})
    {out, _} = run(ws, a, %{"command" => "basename \"$PWD\"; echo $LEMON_SS_X"})
    assert out =~ "sub"
    assert out =~ "hello"

    {out, _} = run(ws, sid(), %{"command" => "basename \"$PWD\"; echo \"x${LEMON_SS_X}x\""})
    refute out =~ "hello"
    assert out =~ "xx"
  end

  test "reset returns to initial state", %{tmp_dir: ws} do
    File.mkdir_p!(Path.join(ws, "sub"))
    a = sid()
    run(ws, a, %{"command" => "cd sub; export LEMON_SS_Y=1"})
    {out, _} = run(ws, a, %{"command" => "echo \"y${LEMON_SS_Y}\"; pwd", "reset" => true})
    assert out =~ "y\n"
    refute out =~ "/sub"
  end

  test "cwd cannot persist outside the workspace (cd .. and symlinks)", %{tmp_dir: tmp} do
    ws = Path.join(tmp, "ws")
    File.mkdir_p!(ws)
    File.mkdir_p!(Path.join(tmp, "outside"))
    File.ln_s!(Path.join(tmp, "outside"), Path.join(ws, "link"))
    a = sid()

    run(ws, a, %{"command" => "cd .."})
    {out, _} = run(ws, a, %{"command" => "pwd -P"})
    assert String.trim(out) |> String.ends_with?("/ws")

    run(ws, a, %{"command" => "cd link"})
    {out, _} = run(ws, a, %{"command" => "pwd -P"})
    assert String.trim(out) |> String.ends_with?("/ws")
  end

  test "replaced saved cwd resolves nested symlinks before parent components", %{tmp_dir: tmp} do
    ws = Path.join(tmp, "ws")
    sub = Path.join(ws, "sub")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(sub)
    File.mkdir_p!(Path.join(ws, "dest"))
    File.mkdir_p!(Path.join(outside, "deep"))
    File.mkdir_p!(Path.join(outside, "dest"))
    a = sid()

    {_, result} = run(ws, a, %{"command" => "cd sub"})
    refute result.is_error
    assert String.ends_with?(ShellState.get(a, ws, self()).cwd, "/sub")

    File.rmdir!(sub)
    File.ln_s!(Path.join(outside, "deep"), Path.join(ws, "hop"))
    File.ln_s!("hop/../dest", sub)
    assert File.dir?(sub)
    refute ShellState.within?(sub, ws)

    {out, result} = run(ws, a, %{"command" => "pwd -P"})
    refute result.is_error
    {physical_workspace, 0} = System.cmd("pwd", ["-P"], cd: ws)
    assert String.trim(out) == String.trim(physical_workspace)
  end

  test "persisted env does not apply to other sessions' background commands", %{tmp_dir: ws} do
    a = sid()
    run(ws, a, %{"command" => "export LEMON_SS_Z=secret"})
    {out, _} = run(ws, sid(), %{"command" => "echo \"z${LEMON_SS_Z}\""})
    refute out =~ "secret"
  end

  for reason <- [:normal, :killed] do
    @exit_reason reason

    test "session #{@exit_reason} exit discards state and rejects late capture", %{tmp_dir: ws} do
      File.mkdir_p!(Path.join(ws, "sub"))
      a = sid()
      owner = start_owner()

      {_, result} =
        run(ws, a, %{"command" => "cd sub; export LEMON_SS_OWNER=secret"}, owner)

      refute result.is_error
      state = ShellState.get(a, ws, owner)
      assert String.ends_with?(state.cwd, "/sub")
      assert state.env["LEMON_SS_OWNER"] == "secret"
      assert is_reference(state.token)

      stop_owner(owner, @exit_reason)

      assert_eventually(fn ->
        stored = :sys.get_state(ShellState)
        not Map.has_key?(stored.sessions, a) and not Map.has_key?(stored.monitors, state.token)
      end)

      {cwd_file, env_file} =
        capture_files(ws, Path.join(ws, "sub"), [{"LEMON_SS_OWNER", "late"}])

      assert :ok = ShellState.capture(a, state.token, ws, cwd_file, env_file, %{})
      refute Map.has_key?(:sys.get_state(ShellState).sessions, a)
      assert %{cwd: nil, env: %{}, token: nil} = ShellState.get(a, ws, owner)
      refute Map.has_key?(:sys.get_state(ShellState).sessions, a)

      {out, result} =
        run(ws, a, %{"command" => "basename \"$PWD\"; printf 'owner=%s\\n' \"$LEMON_SS_OWNER\""})

      refute result.is_error
      assert out =~ "owner=\n"
      refute out =~ "secret"
      refute out =~ "owner=late"
      refute out =~ "sub\n"

      assert :ok = ShellState.capture(a, state.token, ws, cwd_file, env_file, %{})
      assert ShellState.get(a, ws, self()).env == %{}
    end
  end

  test "owner replacement starts empty and fences the previous owner's captures and DOWN",
       %{tmp_dir: ws} do
    File.mkdir_p!(Path.join(ws, "sub"))
    a = sid()
    previous_owner = start_owner()
    replacement_owner = start_owner()

    run(ws, a, %{"command" => "cd sub; export LEMON_SS_OWNER=previous"}, previous_owner)
    previous = ShellState.get(a, ws, previous_owner)
    replacement = ShellState.get(a, ws, replacement_owner)

    assert replacement.cwd == nil
    assert replacement.env == %{}
    refute replacement.token == previous.token
    refute Map.has_key?(:sys.get_state(ShellState).monitors, previous.token)

    {cwd_file, env_file} =
      capture_files(ws, Path.join(ws, "sub"), [{"LEMON_SS_OWNER", "stale"}])

    assert :ok = ShellState.capture(a, previous.token, ws, cwd_file, env_file, %{})
    assert ShellState.get(a, ws, replacement_owner) == replacement

    {_, result} =
      run(ws, a, %{"command" => "export LEMON_SS_OWNER=replacement"}, replacement_owner)

    refute result.is_error
    stop_owner(previous_owner, :killed)
    send(ShellState, {:DOWN, previous.token, :process, previous_owner, :killed})
    current = ShellState.get(a, ws, replacement_owner)
    assert current.token == replacement.token
    assert current.env["LEMON_SS_OWNER"] == "replacement"
    assert ShellState.within?(current.cwd, ws)
    refute current.cwd == previous.cwd

    assert :ok = ShellState.capture(a, previous.token, ws, cwd_file, env_file, %{})
    assert ShellState.get(a, ws, replacement_owner) == current
  end

  test "reset invalidates captures even when the same live owner reuses the session",
       %{tmp_dir: ws} do
    File.mkdir_p!(Path.join(ws, "sub"))
    a = sid()
    previous = ShellState.get(a, ws, self())

    {cwd_file, env_file} =
      capture_files(ws, Path.join(ws, "sub"), [{"LEMON_SS_RESET", "stale"}])

    assert :ok = ShellState.capture(a, previous.token, ws, cwd_file, env_file, %{})
    assert ShellState.get(a, ws, self()).env["LEMON_SS_RESET"] == "stale"
    assert :ok = ShellState.reset(a)
    refute Map.has_key?(:sys.get_state(ShellState).monitors, previous.token)

    assert :ok = ShellState.capture(a, previous.token, ws, cwd_file, env_file, %{})
    refute Map.has_key?(:sys.get_state(ShellState).sessions, a)

    current = ShellState.get(a, ws, self())
    assert current.cwd == nil
    assert current.env == %{}
    refute current.token == previous.token

    assert :ok = ShellState.capture(a, previous.token, ws, cwd_file, env_file, %{})
    assert ShellState.get(a, ws, self()) == current
  end

  test "capture ignores invalid environment names and exported function encodings",
       %{tmp_dir: ws} do
    a = sid()
    state = ShellState.get(a, ws, self())

    entries = [
      {"LEMON_SS_VALID_1", "retained=with\nnewlines"},
      {"_LEMON_SS_VALID", "also-retained"},
      {"", "empty"},
      {"1LEMON_SS", "leading-digit"},
      {"LEMON-SS", "hyphen"},
      {"LEMON.SS", "dot"},
      {"LEMON SS", "space"},
      {"LEMON\nSS", "newline"},
      {"LÉMON_SS", "non-ascii"},
      {"BASH_FUNC_lemon_ss%%", "() { printf exported; }"},
      {"BASH_FUNC_lemon_ss()", "() { printf exported; }"}
    ]

    {cwd_file, env_file} = capture_files(ws, ws, entries)
    assert :ok = ShellState.capture(a, state.token, ws, cwd_file, env_file, %{})

    assert ShellState.get(a, ws, self()).env == %{
             "LEMON_SS_VALID_1" => "retained=with\nnewlines",
             "_LEMON_SS_VALID" => "also-retained"
           }
  end

  test "exported functions do not poison later foreground, background or service launches",
       %{tmp_dir: ws} do
    a = sid()

    on_exit(fn ->
      for {id, %{owner: ^a}} <- ProcessManager.list() do
        ProcessManager.kill(id, :sigkill)
      end
    end)

    {out, result} =
      run(ws, a, %{
        "command" => """
        lemon_ss_exported() { printf 'FUNCTION_BODY\\n'; }
        export -f lemon_ss_exported &&
          bash -c lemon_ss_exported &&
          export LEMON_SS_FUNCTION_SAFE=kept
        """
      })

    refute result.is_error
    assert out =~ "FUNCTION_BODY"
    state = ShellState.get(a, ws, self())
    assert state.env["LEMON_SS_FUNCTION_SAFE"] == "kept"

    assert Enum.all?(Map.keys(state.env), fn name ->
             Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, name)
           end)

    probe = """
    if declare -F lemon_ss_exported >/dev/null; then
      printf 'FUNCTION_LEAKED\\n'
    else
      printf 'FUNCTION_ABSENT\\n'
    fi
    printf 'safe=%s\\n' "$LEMON_SS_FUNCTION_SAFE"
    """

    {out, foreground} = run(ws, a, %{"command" => probe})
    refute foreground.is_error
    assert out =~ "FUNCTION_ABSENT"
    assert out =~ "safe=kept"
    refute out =~ "FUNCTION_LEAKED"

    {_, background} = run(ws, a, %{"command" => probe, "run_in_background" => true})
    refute background.is_error
    assert %{process_id: process_id, background: true} = background.details

    assert_eventually(
      fn ->
        match?({:ok, %{status: :completed, exit_code: 0}}, ProcessManager.poll(process_id))
      end,
      timeout: 5_000
    )

    assert {:ok, %{logs: logs}} = ProcessManager.poll(process_id)
    out = Enum.join(logs, "\n")
    assert out =~ "FUNCTION_ABSENT"
    assert out =~ "safe=kept"
    refute out =~ "FUNCTION_LEAKED"

    {out, service} =
      run(ws, a, %{
        "command" => probe <> "printf 'READY\\n'; read value",
        "name" => "exported-function",
        "ready" => %{"log" => "READY", "timeout_s" => 5}
      })

    refute service.is_error
    assert service.details.service.ready
    assert out =~ "FUNCTION_ABSENT"
    assert out =~ "safe=kept"
    refute out =~ "FUNCTION_LEAKED"
    assert {:ok, %{status: :running}} = ProcessManager.poll(service.details.process_id)
  end

  defp start_owner do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, _reason}
    end)

    owner
  end

  defp stop_owner(owner, reason) do
    ref = Process.monitor(owner)

    case reason do
      :normal -> send(owner, :stop)
      :killed -> Process.exit(owner, :kill)
    end

    assert_receive {:DOWN, ^ref, :process, ^owner, ^reason}
  end

  defp capture_files(ws, cwd, entries) do
    cwd_file = Path.join(ws, "capture.cwd")
    env_file = Path.join(ws, "capture.env")
    File.write!(cwd_file, cwd <> "\n")
    File.write!(env_file, Enum.map(entries, fn {name, value} -> [name, "=", value, <<0>>] end))
    {cwd_file, env_file}
  end
end

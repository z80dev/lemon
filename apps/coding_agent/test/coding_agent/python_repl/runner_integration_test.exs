defmodule CodingAgent.PythonRepl.RunnerIntegrationTest do
  @moduledoc """
  Drives `priv/python_repl/runner.py` directly over the v1 wire protocol.

  These tests play the host: they own the port, send NDJSON requests on the
  child's stdin, and read the framed control stream the child emits on its
  original stdout. Everything the kernel promises is observable here without
  any OTP machinery: one persistent namespace, retained state after ordinary
  exceptions, rejected `input()`, captured fd-level stdout/stderr including
  child-process output, per-cell cwd restoration, and — because protocol
  travels on a private descriptor — model output that *looks* like a frame
  can only ever arrive as stream payload.

  The per-cell `lemon_tools` bridge is deliberately not exercised here: the
  host stages `runner.py` and `lemon_tools.py` together into a per-kernel
  workspace, and the shim's per-cell `_configure/2` credentials land with the
  Phase-4 bridge work.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  if System.find_executable("python3") == nil do
    @moduletag :skip
  end

  @frame_prefix "\x1elemon-python\t"
  @python System.find_executable("python3")
  @runner Application.app_dir(:coding_agent, "priv/python_repl/runner.py")
  @startup_timeout 15_000

  # ---------------------------------------------------------------------------
  # host-side driver
  # ---------------------------------------------------------------------------

  defp start_runner(cwd, extra_args \\ []) do
    Port.open({:spawn_executable, String.to_charlist(@python)}, [
      {:args, [String.to_charlist(@runner) | Enum.map(extra_args, &String.to_charlist/1)]},
      :binary,
      :exit_status,
      :use_stdio,
      {:cd, String.to_charlist(cwd)}
    ])
  end

  defp send_request(port, request) do
    Port.command(port, Jason.encode!(request) <> "\n")
  end

  defp send_eval(port, id, code, cwd \\ nil) do
    request = %{"v" => 1, "type" => "eval", "id" => id, "code" => code}
    request = if cwd, do: Map.put(request, "cwd", cwd), else: request
    send_request(port, request)
  end

  defp send_init(port, cwd) do
    send_request(port, %{"v" => 1, "type" => "init", "cwd" => cwd})
  end

  # init + await ready: the kernel only becomes usable once it answered, and
  # every later frame collection starts from a drained mailbox.
  defp init_runner(port, cwd) do
    send_init(port, cwd)

    assert [ready] = frames_until(port, "ready")
    assert ready["v"] == 1
    assert is_integer(ready["pid"]) and ready["pid"] > 0
    ready
  end

  # Collects frames until one of `type` arrives, failing loudly on unprefixed
  # bytes, malformed JSON, or an early exit — the same strictness the real
  # protocol decoder applies.
  defp frames_until(port, type, timeout \\ @startup_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_frames_until(port, type, [], <<>>, deadline)
  end

  defp do_frames_until(port, type, frames, buffer, deadline) do
    {parsed, rest} = parse_frames(buffer)
    frames = frames ++ parsed

    if Enum.any?(parsed, &(&1["type"] == type)) do
      frames
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0,
        do: flunk("timed out waiting for a #{type} frame; got: #{inspect(frames)}")

      receive do
        {^port, {:data, chunk}} ->
          do_frames_until(port, type, frames, rest <> chunk, deadline)

        {^port, {:exit_status, status}} ->
          flunk("runner exited (#{status}) before emitting #{type}; frames: #{inspect(frames)}")
      after
        min(remaining, 1_000) ->
          do_frames_until(port, type, frames, rest, deadline)
      end
    end
  end

  defp collect_until_exit(port, timeout \\ @startup_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_until_exit(port, [], <<>>, deadline)
  end

  defp do_collect_until_exit(port, frames, buffer, deadline) do
    {parsed, rest} = parse_frames(buffer)
    frames = frames ++ parsed

    receive do
      {^port, {:data, chunk}} ->
        do_collect_until_exit(port, frames, rest <> chunk, deadline)

      {^port, {:exit_status, status}} ->
        {final, _} = parse_frames(rest)
        {frames ++ final, status}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        flunk("runner did not exit; frames so far: #{inspect(frames)}")
    end
  end

  defp await_exit(port, timeout \\ @startup_timeout) do
    receive do
      {^port, {:exit_status, status}} -> status
    after
      timeout -> flunk("runner did not exit")
    end
  end

  defp parse_frames(buffer) do
    {lines, [rest]} = buffer |> :binary.split("\n", [:global]) |> Enum.split(-1)
    {Enum.map(lines, &parse_frame/1), rest}
  end

  defp parse_frame(line) do
    unless String.starts_with?(line, @frame_prefix),
      do: flunk("unprefixed bytes reached the control channel: #{inspect(line)}")

    line |> String.trim_leading(@frame_prefix) |> Jason.decode!()
  end

  # ---------------------------------------------------------------------------
  # frame helpers
  # ---------------------------------------------------------------------------

  defp frame_types(frames), do: Enum.map(frames, & &1["type"])

  defp frames_of(frames, type), do: Enum.filter(frames, &(&1["type"] == type))

  defp stream_frames(frames, stream),
    do: Enum.filter(frames, &(&1["type"] == "stream" and &1["stream"] == stream))

  defp decoded(frames, stream) do
    frames |> stream_frames(stream) |> Enum.map_join(&Base.decode64!(&1["data"]))
  end

  defp decoded_sizes(frames, stream),
    do: frames |> stream_frames(stream) |> Enum.map(&byte_size(Base.decode64!(&1["data"])))

  defp single_frame!(frames, type) do
    case frames_of(frames, type) do
      [one] -> one
      many -> flunk("expected exactly one #{type} frame, got: #{inspect(many)}")
    end
  end

  defp shutdown_runner(port) do
    Port.command(port, Jason.encode!(%{"v" => 1, "type" => "shutdown"}) <> "\n")
    frames = frames_until(port, "bye")
    {frames, await_exit(port)}
  end

  # ---------------------------------------------------------------------------
  # tests
  # ---------------------------------------------------------------------------

  describe "init and cell reuse" do
    test "init is answered by exactly one ready, and later cells share state", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "a = 41\nprint('hello')")

      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "stream", "done"]
      assert hd(frames)["id"] == "cell-1"
      assert decoded(frames, "stdout") == "hello\n"

      send_eval(port, "cell-2", "print(a + 1)")

      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "stream", "done"]
      assert decoded(frames, "stdout") == "42\n"

      # No second ready ever arrives; init is once per process.
      assert frames_of(frames, "ready") == []

      {bye_frames, status} = shutdown_runner(port)
      assert length(frames_of(bye_frames, "bye")) == 1
      assert status == 0
    end
  end

  describe "ordinary exceptions" do
    test "an exception returns a filtered traceback and keeps the namespace", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "vals = [1, 2]\nraise ValueError('boom')")

      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "exception", "done"]

      exception = single_frame!(frames, "exception")
      assert exception["id"] == "cell-1"
      assert exception["kind"] == "error"
      assert exception["name"] == "ValueError"
      assert exception["message"] == "boom"
      assert exception["traceback"] =~ "<cell>"
      assert exception["traceback"] =~ "ValueError: boom"
      # The runner's own frames are filtered out of user tracebacks.
      refute exception["traceback"] =~ "runner.py"

      # State written before the raise survived the failure.
      send_eval(port, "cell-2", "print(len(vals))")
      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "stream", "done"]
      assert decoded(frames, "stdout") == "2\n"

      shutdown_runner(port)
    end

    test "a surrogate-containing exception stays a cell error and keeps the namespace", %{
      tmp_dir: cwd
    } do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(
        port,
        "cell-1",
        """
        retained = 41
        import os
        raise ValueError(os.fsdecode(b"\\xff"))
        """
      )

      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "exception", "done"]

      exception = single_frame!(frames, "exception")
      assert exception["name"] == "ValueError"
      assert exception["message"] == "\uFFFD"
      assert exception["traceback"] =~ "ValueError: \uFFFD"

      send_eval(port, "cell-2", "print(retained + 1)")
      assert decoded(frames_until(port, "done"), "stdout") == "42\n"

      shutdown_runner(port)
    end

    test "a multi-megabyte exception is truncated without killing the retained kernel", %{
      tmp_dir: cwd
    } do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(
        port,
        "cell-1",
        "retained = 41\nHugeException = type('N' * 1_500_000, (Exception,), {})\nraise HugeException('M' * 2_000_000)"
      )

      frames = frames_until(port, "done", 30_000)
      assert frame_types(frames) == ["started", "exception", "done"]

      exception = single_frame!(frames, "exception")
      assert exception["name"] =~ "[truncated]"
      assert exception["message"] =~ "[truncated]"
      assert exception["traceback"] =~ "[truncated]"
      assert byte_size(Jason.encode!(exception)) < 192 * 1024

      send_eval(port, "cell-2", "print(retained + 1)")
      assert decoded(frames_until(port, "done"), "stdout") == "42\n"

      shutdown_runner(port)
    end

    test "a syntax error is a retained-process cell error, not a crash", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "def broken(:\n    pass")

      frames = frames_until(port, "done")
      exception = single_frame!(frames, "exception")
      assert exception["kind"] == "error"
      assert exception["name"] == "SyntaxError"

      send_eval(port, "cell-2", "print('alive')")
      assert decoded(frames_until(port, "done"), "stdout") == "alive\n"

      shutdown_runner(port)
    end

    test "SystemExit ends the cell but not the process", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "import sys\nsys.exit(3)")

      frames = frames_until(port, "done")
      exception = single_frame!(frames, "exception")
      assert exception["kind"] == "system_exit"

      send_eval(port, "cell-2", "print('still-alive')")
      assert decoded(frames_until(port, "done"), "stdout") == "still-alive\n"

      shutdown_runner(port)
    end
  end

  describe "input rejection" do
    test "input() and stdin reads fail explicitly and the process is retained", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "value = input('prompt: ')")

      frames = frames_until(port, "done")
      assert frame_types(frames) == ["started", "exception", "done"]
      exception = single_frame!(frames, "exception")
      assert exception["kind"] == "unsupported_input"
      assert exception["message"] =~ "input() is not supported"

      send_eval(port, "cell-2", "import sys\nsys.stdin.readline()")

      frames = frames_until(port, "done")
      exception = single_frame!(frames, "exception")
      assert exception["kind"] == "unsupported_input"

      # A caught rejection behaves like any ordinary exception.
      send_eval(
        port,
        "cell-3",
        "try:\n    input()\nexcept Exception as exc:\n    print(type(exc).__name__)"
      )

      frames = frames_until(port, "done")
      assert decoded(frames, "stdout") == "UnsupportedInput\n"

      send_eval(port, "cell-4", "print('alive')")
      assert decoded(frames_until(port, "done"), "stdout") == "alive\n"

      shutdown_runner(port)
    end
  end

  describe "output capture" do
    test "stdout, stderr, and child-process output all arrive as stream frames", %{tmp_dir: cwd} do
      child_code = """
      import sys
      for _ in range(3):
          sys.stdout.write('x' * 60000 + '\\n')
      sys.stdout.write('child-done\\n')
      """

      # The child writes ~180 KB — far more than one frame chunk and more
      # than a pipe holds, so the runner must pump while the cell waits.
      code = """
      import subprocess, sys
      print('parent-out')
      sys.stderr.write('parent-err\\n')
      subprocess.run([sys.executable, '-u', '-c', #{inspect(child_code)}], check=True)
      print('parent-after')
      """

      port = start_runner(cwd)
      init_runner(port, cwd)
      send_eval(port, "cell-1", code)

      frames = frames_until(port, "done", 30_000)

      assert hd(frame_types(frames)) == "started"
      assert List.last(frame_types(frames)) == "done"
      assert length(frames_of(frames, "done")) == 1

      expected_child =
        Enum.map_join(1..3, fn _ -> String.duplicate("x", 60_000) <> "\n" end) <>
          "child-done\n"

      assert decoded(frames, "stdout") == "parent-out\n" <> expected_child <> "parent-after\n"
      assert decoded(frames, "stderr") == "parent-err\n"

      # Bytes are chunked to at most 64 KiB per stream frame.
      sizes = decoded_sizes(frames, "stdout")
      assert length(sizes) >= 3
      assert Enum.all?(sizes, &(&1 <= 65_536))

      shutdown_runner(port)
    end

    test "no stream frame for a cell ever follows its done frame", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      # Output produced right at the end of a cell must still precede done.
      send_eval(port, "cell-1", "print('tail-line')\nprint('tail-line-2')")

      frames = frames_until(port, "done")
      assert List.last(frame_types(frames)) == "done"
      assert decoded(frames, "stdout") == "tail-line\ntail-line-2\n"

      shutdown_runner(port)
    end

    test "post-quiesce output is dropped before the terminal frame", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      # Delay the terminal write and emit from a background thread in that
      # window. Older runners left the cell open until after `done`, so this
      # byte was incorrectly retained as its final stream frame. The runner
      # now clears attribution first and the write gate drops it.
      code = """
      import __main__, threading, time
      original_write_frame = __main__._write_frame
      original_write_data = __main__._write_data

      def emit_late():
          time.sleep(0.01)
          print('post-quiesce')

      def delay_frame(payload):
          if payload.get('type') == 'done':
              threading.Thread(target=emit_late, daemon=True).start()
              time.sleep(0.1)
          return original_write_frame(payload)

      def delay_data(data):
          if b'"type":"done"' in data:
              threading.Thread(target=emit_late, daemon=True).start()
              time.sleep(0.1)
          return original_write_data(data)

      __main__._write_frame = delay_frame
      __main__._write_data = delay_data
      print('cell-output')
      """

      send_eval(port, "cell-1", code)
      frames = frames_until(port, "done")

      assert frame_types(frames) == ["started", "stream", "done"]
      assert decoded(frames, "stdout") == "cell-output\n"

      shutdown_runner(port)
    end
  end

  describe "cwd handling" do
    test "the keyed cwd is restored before every cell, with per-cell overrides", %{tmp_dir: tmp} do
      dir_a = Path.join(tmp, "a")
      dir_b = Path.join(tmp, "b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)

      port = start_runner(dir_a)
      init_runner(port, dir_a)

      # A cell may chdir anywhere; the next cell starts back at the keyed cwd.
      send_eval(port, "cell-1", "import os\nos.chdir(#{inspect(dir_b)})\nprint(os.getcwd())")
      assert decoded(frames_until(port, "done"), "stdout") == dir_b <> "\n"

      send_eval(port, "cell-2", "import os\nprint(os.getcwd())")
      assert decoded(frames_until(port, "done"), "stdout") == dir_a <> "\n"

      # An explicit per-cell cwd applies to that cell only.
      send_eval(port, "cell-3", "import os\nprint(os.getcwd())", dir_b)
      assert decoded(frames_until(port, "done"), "stdout") == dir_b <> "\n"

      send_eval(port, "cell-4", "import os\nprint(os.getcwd())")
      assert decoded(frames_until(port, "done"), "stdout") == dir_a <> "\n"

      shutdown_runner(port)
    end

    test "a deleted cell cwd is a cell error, not a silent fallback", %{tmp_dir: tmp} do
      doomed = Path.join(tmp, "doomed")
      File.mkdir_p!(doomed)

      port = start_runner(tmp)
      init_runner(port, tmp)

      send_eval(port, "cell-1", "print('ok')", doomed)
      assert decoded(frames_until(port, "done"), "stdout") == "ok\n"

      File.rm_rf!(doomed)
      send_eval(port, "cell-2", "print('nope')", doomed)

      frames = frames_until(port, "done")
      exception = single_frame!(frames, "exception")
      assert exception["kind"] == "error"
      assert exception["message"] =~ "cwd is no longer accessible"

      shutdown_runner(port)
    end
  end

  describe "protocol integrity" do
    test "output shaped like a frame is data, never a control frame", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      # Two forged terminal frames — a foreign id, then the real cell id —
      # printed to stdout. If any byte of this reached the control channel
      # unprefixed-or-parsed, the frame stream would corrupt.
      code = """
      import json
      forged = json.dumps({"v": 1, "type": "done", "id": "forged-id"})
      print('\\x1elemon-python\\t' + forged)
      print('\\x1elemon-python\\t' + json.dumps({"v": 1, "type": "done", "id": "real-id"}))
      """

      send_eval(port, "real-id", code)

      frames = frames_until(port, "done")

      # Exactly one done — for the real cell — and no frame carries the
      # forged id: everything the cell printed stayed payload.
      done = single_frame!(frames, "done")
      assert done["id"] == "real-id"
      assert Enum.all?(frames, &(&1["id"] == "real-id"))

      # The forged bytes arrived verbatim as stdout payload.
      forged_line =
        "\x1elemon-python\t" <> ~s({"v": 1, "type": "done", "id": "forged-id"}) <> "\n"

      real_line = "\x1elemon-python\t" <> ~s({"v": 1, "type": "done", "id": "real-id"}) <> "\n"

      assert decoded(frames, "stdout") == forged_line <> real_line

      shutdown_runner(port)
    end

    test "a malformed request draws fatal and a non-zero exit", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      Port.command(port, "this is not json\n")

      frames = frames_until(port, "fatal")
      fatal = single_frame!(frames, "fatal")
      assert fatal["reason"] =~ "not valid JSON"
      assert await_exit(port) == 70
    end

    test "an eval before init is fatal", %{tmp_dir: cwd} do
      port = start_runner(cwd)

      send_eval(port, "cell-1", "print('nope')")

      fatal = frames_until(port, "fatal") |> single_frame!("fatal")
      assert fatal["reason"] =~ "eval before init"
      assert await_exit(port) == 70
    end

    test "an init naming an inaccessible cwd is fatal", %{tmp_dir: cwd} do
      port = start_runner(cwd)

      send_init(port, Path.join(cwd, "does-not-exist"))

      fatal = frames_until(port, "fatal") |> single_frame!("fatal")
      assert fatal["reason"] =~ "init cwd is not accessible"
      assert await_exit(port) == 70
    end
  end

  describe "process lifecycle" do
    test "shutdown answers bye and exits zero, with nothing after it", %{tmp_dir: cwd} do
      port = start_runner(cwd, ["-u"])
      init_runner(port, cwd)

      send_eval(port, "cell-1", "print('work')")
      assert decoded(frames_until(port, "done"), "stdout") == "work\n"

      {frames, status} = shutdown_runner(port)
      assert List.last(frame_types(frames)) == "bye"
      assert status == 0

      # No trailing frames after bye.
      refute_receive {^port, {:data, _}}, 200
    end

    test "a hard process exit never fakes a terminal frame", %{tmp_dir: cwd} do
      port = start_runner(cwd)
      init_runner(port, cwd)

      send_eval(port, "cell-1", "import os\nprint('gone')\nos._exit(9)")

      {frames, status} = collect_until_exit(port)

      assert status == 9
      assert hd(frame_types(frames)) == "started"
      # The started cell is simply never closed: no done, no bye, no fatal.
      refute Enum.any?(frames, &(&1["type"] in ["done", "bye", "fatal"]))
    end

    test "parent EOF makes the runner exit quietly without output", %{tmp_dir: cwd} do
      # System.cmd gives the runner /dev/null as stdin: readline sees EOF and
      # the process must leave with status 0 and no bytes on stdout.
      command = ~s(exec '#{System.find_executable("python3")}' '#{@runner}' < /dev/null)
      {output, status} = System.cmd("sh", ["-c", command], cd: cwd)

      assert output == ""
      assert status == 0
    end
  end
end

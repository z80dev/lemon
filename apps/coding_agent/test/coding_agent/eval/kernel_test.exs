defmodule CodingAgent.Eval.KernelTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Eval.{Kernel, Output}

  @marker "\x1eLEMONEVAL:tok:"
  @python System.find_executable("python3")

  @tag :tmp_dir
  @tag :python3
  test "status stays responsive while process-group observation waits", %{tmp_dir: cwd} do
    test_pid = self()

    runner = fn kind, io ->
      send(test_pid, {:process_io, kind, self()})
      receive do: (:release -> io.())
    end

    slot =
      start_supervised!(
        {Kernel, key: make_ref(), language: "py", cwd: cwd, runtime: @python, io_runner: runner}
      )

    run =
      Task.async(fn ->
        {:ok, %{ref: ref}} = result = Kernel.run(slot, "1")
        assert_receive {:lemon_eval, ^ref, {:result, _}}, 5_000
        result
      end)

    assert_receive {:process_io, :verify, worker}, 5_000
    assert {:verifying, %{operation: %{pid: ^worker}}} = :sys.get_state(slot)
    assert is_integer(:gen_statem.call(slot, :os_pid, 500))
    assert {:error, :busy} = Kernel.run(slot, "2")
    send(worker, :release)
    assert {:ok, %{cell: 1}} = Task.await(run, 5_000)
  end

  @tag :tmp_dir
  @tag :python3
  test "status stays responsive during SIGINT and cleanup IO", %{tmp_dir: cwd} do
    test_pid = self()

    runner = fn
      :verify, io ->
        io.()

      kind, io ->
        send(test_pid, {:process_io, kind, self()})
        receive do: (:release -> io.())
    end

    slot =
      start_supervised!(
        {Kernel, key: make_ref(), language: "py", cwd: cwd, runtime: @python, io_runner: runner}
      )

    assert {:ok, %{ref: ref}} =
             Kernel.run(
               slot,
               "import threading; print('ready', flush=True); threading.Event().wait()"
             )

    await_output(ref, "ready")
    interrupt = Task.async(fn -> Kernel.interrupt(slot, ref, :timeout) end)
    assert_receive {:process_io, :interrupt, worker}, 5_000
    assert {:interrupting, _} = :sys.get_state(slot)
    assert is_integer(:gen_statem.call(slot, :os_pid, 500))
    send(worker, :release)
    assert :preserved = Task.await(interrupt, 5_000)
    assert {:idle, _} = :sys.get_state(slot)

    assert {:ok, %{ref: ref}} =
             Kernel.run(slot, "print('ready', flush=True); threading.Event().wait()")

    await_output(ref, "ready")
    abort = Task.async(fn -> Kernel.interrupt(slot, ref, :aborted) end)
    assert_receive {:process_io, {:stop, :aborted, :idle}, worker}, 5_000
    assert {:stopping, _} = :sys.get_state(slot)
    assert is_integer(:gen_statem.call(slot, :os_pid, 500))
    send(worker, :release)
    assert :killed = Task.await(abort, 5_000)
    assert {:idle, _} = :sys.get_state(slot)
    assert Kernel.os_pid(slot) == nil
  end

  defp await_output(ref, expected, output \\ "") do
    if String.contains?(output, expected) do
      :ok
    else
      assert_receive {:lemon_eval, ^ref, {:output, chunk}}, 5_000
      await_output(ref, expected, output <> chunk)
    end
  end

  describe "split_frames/2" do
    test "separates frames from raw output, including frames after a partial line" do
      data = "hello\npartial" <> @marker <> ~s({"type":"result","id":1}\n) <> "tail\n"

      assert {[%{"type" => "result", "id" => 1}], raw, ""} = Kernel.split_frames(data, @marker)
      assert IO.iodata_to_binary(raw) == "hello\npartialtail\n"
    end

    test "keeps incomplete frames and possible marker prefixes for the next chunk" do
      assert {[], raw, rest} = Kernel.split_frames("out\x1eLEMON", @marker)
      assert IO.iodata_to_binary(raw) == "out"

      assert {[], raw, rest} = Kernel.split_frames(rest <> "EVAL:tok:{\"id\":", @marker)
      assert IO.iodata_to_binary(raw) == ""
      assert {[%{"id" => 2}], _raw, ""} = Kernel.split_frames(rest <> "2}\n", @marker)
    end

    test "a malformed framed line degrades to raw output" do
      assert {[], raw, ""} = Kernel.split_frames(@marker <> "not json\n", @marker)
      assert IO.iodata_to_binary(raw) == "not json\n"
    end
  end

  test "Output decodes UTF-8 split across chunks and strips ANSI sequences" do
    <<first::binary-size(1), second::binary>> = "é"
    {acc, ""} = Output.append(Output.new(), first)
    {acc, "é"} = Output.append(acc, second)
    {acc, "red"} = Output.append(acc, "\e[31mred\e[0m")
    assert Output.finalize(acc) == %{output: "éred", truncated: false, full_output_path: nil}
    acc = Output.append_block(Output.new(), "\e[31mframed error\e[0m")
    assert Output.finalize(acc).output == "framed error"
  end

  @tag :tmp_dir
  test "rich output side channel rejects oversized, invalid and excessive records", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "display.jsonl")
    File.write!(path, Jason.encode!(%{mime: "text/markdown", data: "**ok**"}) <> "\n")
    assert {:ok, [%LemonAi.Types.TextContent{text: "**ok**"}]} = Output.read_displays(path)
    File.write!(path, String.duplicate("x", 4 * 1024 * 1024 + 1))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, String.duplicate(~s({"mime":"text/markdown","data":"x"}\n), 33))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, ~s({"mime":"image/png","data":"invalid base64"}\n))
    assert {:error, _} = Output.read_displays(path)
    File.write!(path, ~s({"mime":"image/png","data":"eA=="}\n))
    assert {:error, _} = Output.read_displays(path)
  end

  @tag :tmp_dir
  test "a ready frame naming a foreign group leader is refused, not signalled", %{
    tmp_dir: tmp_dir
  } do
    # A real process that leads its own group but is not the kernel's.
    foreign = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    {:os_pid, foreign_pid} = Port.info(foreign, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(foreign_pid)]) end)

    runtime = Path.join(tmp_dir, "forging-runtime")

    File.write!(runtime, """
    #!/bin/sh
    printf '\\036LEMONEVAL:%s:{"type":"ready","pid":#{foreign_pid}}\\n' "$LEMON_EVAL_TOKEN"
    exec cat
    """)

    File.chmod!(runtime, 0o700)

    {:ok, slot} =
      Kernel.start_link(key: make_ref(), language: "js", cwd: tmp_dir, runtime: runtime)

    assert {:error, message} = Kernel.run(slot, "1")
    assert message =~ "could not prove the kernel's own process group"
    assert Kernel.os_pid(slot) == nil
    assert Port.info(foreign) != nil
    assert match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(foreign_pid)]))
  end
end

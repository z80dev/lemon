defmodule LemonPlatformTest.Compliance.CodexSubagentTest do
  @moduledoc """
  The suite run against a real vendor CLI wrapper.

  The stub suite proves the case template; this one proves it against a runner
  that actually spawns a subprocess, parses a JSONL dialect and translates it
  into `LemonCore.RunEvents`. The `codex` binary is faked on `PATH` — a shell
  script emitting three lines of the codex event stream — so the probe is
  offline, deterministic, and exercises the same code a real run would.

  `async: false` for two reasons: the registry round-trip is global, and so is
  `PATH`.
  """

  use LemonPlatformTest.SubagentRunnerCase,
    async: false,
    runner: LemonCliRunners.CodexSubagent,
    run_probe: {__MODULE__, :start_opts}

  @fake_codex """
  #!/bin/sh
  # Drain the prompt on stdin before answering, so the parent never sees EPIPE.
  cat > /dev/null
  printf '%s\\n' '{"type":"thread.started","thread_id":"fake-thread"}'
  printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","id":"1","text":"pong"}}'
  printf '%s\\n' '{"type":"turn.completed"}'
  """

  setup do
    dir =
      Path.join(System.tmp_dir!(), "lemon_fake_codex_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    script = Path.join(dir, "codex")
    File.write!(script, @fake_codex)
    File.chmod!(script, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (original_path || ""))

    on_exit(fn ->
      if original_path do
        System.put_env("PATH", original_path)
      else
        System.delete_env("PATH")
      end

      File.rm_rf!(dir)
    end)

    {:ok, cwd: dir}
  end

  def start_opts(context), do: [prompt: "ping", cwd: context.cwd, timeout: 30_000]

  test "the faked run reports the answer and a resume token", context do
    assert {:ok, session} = LemonCliRunners.CodexSubagent.start(start_opts(context))

    events =
      LemonPlatformTest.SubagentRunnerCase.drain_events(
        LemonCliRunners.CodexSubagent,
        session,
        10_000
      )

    assert Enum.any?(
             events,
             &match?({:started, %LemonCore.ResumeToken{value: "fake-thread"}}, &1)
           )

    assert {:completed, answer, opts} = List.last(events)
    assert answer =~ "pong"
    assert opts[:ok] == true
  end
end

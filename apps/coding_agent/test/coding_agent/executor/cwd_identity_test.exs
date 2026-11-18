defmodule CodingAgent.Executor.CwdIdentityTest do
  @moduledoc """
  A request bound to a directory identity (`meta.cwd_identity`) starts a session
  only in that exact directory object, and its tools refuse to run once the
  path names another directory.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Executor.SessionRunner
  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, ToolCall, Usage}
  alias LemonGateway.ExecutionRequest

  @moduletag :tmp_dir

  test "a session starts in the bound directory", %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    run_ref = make_ref()

    {:ok, _runner} =
      SessionRunner.start_link(
        request: request(cwd, %{cwd_identity: identity(cwd)}),
        opts: %{stream_fn: stream_fn("bound")},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true}}, 10_000
  end

  test "a directory replaced after validation is refused before the session starts", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    checked = identity(cwd)

    # Same path, different directory object (rename-and-recreate)...
    File.rename!(cwd, Path.join(tmp_dir, "original"))
    File.mkdir_p!(cwd)
    assert_refused(request(cwd, %{cwd_identity: checked}))

    # ...or a symlink to another tree.
    File.rm_rf!(cwd)
    File.mkdir_p!(Path.join(tmp_dir, "elsewhere"))
    File.ln_s!(Path.join(tmp_dir, "elsewhere"), cwd)
    assert_refused(request(cwd, %{cwd_identity: checked}))

    # A malformed binding fails closed too.
    assert_refused(request(Path.join(tmp_dir, "original"), %{cwd_identity: %{"inode" => 1}}))
  end

  test "goal judge and continuation runs without a bound identity never start", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "goal")
    File.mkdir_p!(cwd)

    for origin <- [:goal, :goal_judge] do
      assert_refused(request(cwd, %{origin: origin}))
    end
  end

  test "a goal run whose directory is swapped after submission is refused at start", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "goal")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(tmp_dir, "outside"))
    # Submitted (bound to the checked directory), then swapped while queued.
    submitted = request(cwd, %{origin: :goal, cwd_identity: identity(cwd)})
    File.rename!(cwd, Path.join(tmp_dir, "checked"))
    File.ln_s!(Path.join(tmp_dir, "outside"), cwd)
    assert_refused(submitted)
  end

  test "a goal run whose directory is swapped after start refuses its tool calls", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "goal")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(cwd)
    File.mkdir_p!(outside)
    run_ref = make_ref()

    swap = fn ->
      File.rename!(cwd, Path.join(tmp_dir, "checked"))
      File.ln_s!(outside, cwd)
    end

    {:ok, _runner} =
      SessionRunner.start_link(
        request: request(cwd, %{origin: :goal, cwd_identity: identity(cwd)}),
        opts: %{stream_fn: write_then_finish(swap)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 10_000
    refute File.exists?(Path.join(outside, "marker.txt"))
  end

  test "a directory swapped while approval is pending is refused after approval", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "goal")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(cwd)
    File.mkdir_p!(outside)
    owner = self()

    # The approval is granted only after the directory was swapped for a link
    # to another tree: the call passed the pre-approval check, so only a
    # check after approval returns can catch it.
    swap_then_approve = fn _request ->
      send(owner, :approval_requested)
      File.rename!(cwd, Path.join(tmp_dir, "checked"))
      File.ln_s!(outside, cwd)
      {:ok, :approved, :once}
    end

    write = approval_gated_write(cwd, identity(cwd), swap_then_approve)

    assert {:error, message} =
             write.execute.("call", %{"path" => "marker.txt", "content" => "x"}, nil, nil)

    assert_received :approval_requested
    assert message =~ "Working directory changed"
    refute File.exists?(Path.join(outside, "marker.txt"))
    refute File.exists?(Path.join(tmp_dir, "checked/marker.txt"))
  end

  test "an approved call in the unchanged bound directory still runs", %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "goal")
    File.mkdir_p!(cwd)
    write = approval_gated_write(cwd, identity(cwd), fn _ -> {:ok, :approved, :once} end)

    result = write.execute.("call", %{"path" => "marker.txt", "content" => "x"}, nil, nil)
    assert %LemonAgent.Types.AgentToolResult{is_error: false} = result

    assert File.read!(Path.join(cwd, "marker.txt")) == "x"
  end

  defp approval_gated_write(cwd, identity, approve) do
    [write] =
      CodingAgent.ToolRegistry.get_tools(cwd,
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["write"],
        tool_policy: LemonCore.ToolPolicy.custom(require_approval: ["write"]),
        cwd_identity: identity,
        approval_context: %{session_id: "cwd-identity-approval", approval_request_fun: approve},
        tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(Path.dirname(cwd))
      )

    write
  end

  test "tools run in the bound directory while it is unchanged", %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    run_ref = make_ref()

    {:ok, _runner} =
      SessionRunner.start_link(
        request: request(cwd, %{cwd_identity: identity(cwd)}),
        opts: %{stream_fn: write_then_finish(fn -> :ok end)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true}}, 10_000
    assert File.read!(Path.join(cwd, "marker.txt")) == "written"
  end

  test "a directory replaced after verification and before the first tool call is refused",
       %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    original = Path.join(tmp_dir, "original")
    run_ref = make_ref()

    # The session started (identity verified); the model's first reply then
    # arrives after the path was renamed away and recreated: same path and
    # same resolved location, but a different directory object.
    swap = fn ->
      File.rename!(cwd, original)
      File.mkdir_p!(cwd)
    end

    {:ok, _runner} =
      SessionRunner.start_link(
        request: request(cwd, %{cwd_identity: identity(cwd)}),
        opts: %{stream_fn: write_then_finish(swap)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 10_000
    refute File.exists?(Path.join(cwd, "marker.txt"))
    refute File.exists?(Path.join(original, "marker.txt"))
  end

  test "a confined deny-bash session cannot rewrite controller metadata with file tools", %{
    tmp_dir: tmp_dir
  } do
    # A kanban worker's worktree and, outside it, the controller repository's
    # administrative metadata for that worktree.
    cwd = Path.join(tmp_dir, "worktrees/kanban-task")
    File.mkdir_p!(cwd)
    admin = Path.join(tmp_dir, "repos/board.git/worktrees/kanban-task")
    File.mkdir_p!(admin)
    commondir = Path.join(admin, "commondir")
    File.write!(commondir, "../..\n")
    run_ref = make_ref()

    calls = [
      {"write", %{"path" => commondir, "content" => "/tmp/evil-repo\n"}},
      {"write",
       %{"path" => "../../repos/board.git/worktrees/kanban-task/commondir", "content" => "x\n"}},
      {"write", %{"path" => "~/../../#{commondir}", "content" => "x\n"}},
      {"patch",
       %{
         "patch_text" =>
           "*** Begin Patch\n*** Add File: #{admin}/config.worktree\n+[core]\n+\tfsmonitor = /bin/sh\n*** End Patch\n"
       }},
      {"edit",
       %{"path" => commondir, "mode" => "text", "old_text" => "../..", "new_text" => "/tmp/evil"}},
      # Inside the worktree, writes still work.
      {"write", %{"path" => "inside.txt", "content" => "ok"}}
    ]

    {:ok, _runner} =
      SessionRunner.start_link(
        request:
          request(
            cwd,
            %{cwd_identity: identity(cwd), mutation_root: cwd},
            LemonCore.ToolPolicy.custom(deny: ["bash"])
          ),
        opts: %{stream_fn: calls_then_finish(calls)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 10_000
    assert File.read!(commondir) == "../..\n"
    refute File.exists?(Path.join(admin, "config.worktree"))
    assert File.read!(Path.join(cwd, "inside.txt")) == "ok"
  end

  test "a confined session cannot escape through a symlinked ancestor directory", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "worktrees/kanban-task")
    outside = Path.join(tmp_dir, "repos/board.git/worktrees/kanban-task")
    File.mkdir_p!(Path.join(outside, "deep"))
    File.write!(Path.join(outside, "deep/commondir"), "../..\n")
    File.write!(Path.join(outside, "deep/victim"), "victim\n")
    # A pre-existing symlink a level below the worktree root: every target
    # beneath `a/link/` names a path inside the worktree but resolves outside.
    File.mkdir_p!(Path.join(cwd, "a"))
    File.ln_s!(outside, Path.join(cwd, "a/link"))
    run_ref = make_ref()

    calls = [
      {"patch",
       %{
         "patch_text" =>
           "*** Begin Patch\n*** Update File: a/link/deep/commondir\n@@\n-../..\n+/tmp/evil\n*** End Patch\n"
       }},
      {"patch",
       %{"patch_text" => "*** Begin Patch\n*** Delete File: a/link/deep/victim\n*** End Patch\n"}},
      {"patch",
       %{
         "patch_text" =>
           "*** Begin Patch\n*** Add File: a/link/deep/config.worktree\n+[core]\n*** End Patch\n"
       }},
      {"patch",
       %{
         "patch_text" =>
           "*** Begin Patch\n*** Update File: a/link/deep/commondir\n*** Move to: moved\n@@\n-../..\n+../..\n*** End Patch\n"
       }},
      {"write", %{"path" => "a/link/deep/commondir", "content" => "/tmp/evil\n"}},
      {"edit",
       %{
         "path" => "a/link/deep/commondir",
         "mode" => "text",
         "old_text" => "../..",
         "new_text" => "/tmp/evil"
       }},
      # A patch inside the worktree (no symlink) still works.
      {"patch",
       %{"patch_text" => "*** Begin Patch\n*** Add File: inside.txt\n+ok\n*** End Patch\n"}}
    ]

    {:ok, _runner} =
      SessionRunner.start_link(
        request:
          request(
            cwd,
            %{cwd_identity: identity(cwd), mutation_root: cwd},
            LemonCore.ToolPolicy.custom(deny: ["bash"])
          ),
        opts: %{stream_fn: calls_then_finish(calls)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 10_000
    assert File.read!(Path.join(outside, "deep/commondir")) == "../..\n"
    assert File.read!(Path.join(outside, "deep/victim")) == "victim\n"
    refute File.exists?(Path.join(outside, "deep/config.worktree"))
    refute File.exists?(Path.join(cwd, "moved"))
    assert File.read!(Path.join(cwd, "inside.txt")) == "ok"
  end

  # The same targets through the patch tool built exactly as a confined
  # session builds it, without the session's filesystem checkpoint layer (which
  # incidentally refuses symlinked parents): patch's own validation must hold.
  test "the confined patch tool refuses targets beneath a symlinked ancestor", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "worktrees/kanban-task")
    outside = Path.join(tmp_dir, "repos/board.git/worktrees/kanban-task")
    File.mkdir_p!(Path.join(outside, "deep"))
    File.write!(Path.join(outside, "deep/commondir"), "../..\n")
    File.write!(Path.join(outside, "deep/victim"), "victim\n")
    File.mkdir_p!(Path.join(cwd, "a/b"))
    File.ln_s!(outside, Path.join(cwd, "a/b/link"))
    File.write!(Path.join(cwd, "inside.txt"), "x\n")
    patch = CodingAgent.Tools.Patch.tool(cwd, confine_mutations_to: cwd)

    for text <- [
          "*** Begin Patch\n*** Update File: a/b/link/deep/commondir\n@@\n-../..\n+/tmp/evil\n*** End Patch\n",
          "*** Begin Patch\n*** Delete File: a/b/link/deep/victim\n*** End Patch\n",
          "*** Begin Patch\n*** Add File: a/b/link/deep/config.worktree\n+[core]\n*** End Patch\n",
          "*** Begin Patch\n*** Update File: inside.txt\n*** Move to: a/b/link/deep/moved\n@@\n-x\n+x\n*** End Patch\n"
        ] do
      assert {:error, _} = patch.execute.("call", %{"patch_text" => text}, nil, nil), text
    end

    assert File.read!(Path.join(outside, "deep/commondir")) == "../..\n"
    assert File.read!(Path.join(outside, "deep/victim")) == "victim\n"
    refute File.exists?(Path.join(outside, "deep/config.worktree"))
    assert File.read!(Path.join(cwd, "inside.txt")) == "x\n"
    refute File.exists?(Path.join(outside, "deep/moved"))

    # Ordinary targets inside the worktree still work.
    assert %LemonAgent.Types.AgentToolResult{} =
             patch.execute.(
               "call",
               %{"patch_text" => "*** Begin Patch\n*** Add File: a/ok.txt\n+ok\n*** End Patch\n"},
               nil,
               nil
             )

    assert File.exists?(Path.join(cwd, "a/ok.txt"))
  end

  test "a cron run's file tools write its own memory file and no other operator state", %{
    tmp_dir: tmp_dir
  } do
    home = Path.join(tmp_dir, "home")
    memory_dir = Path.join([home, ".lemon", "cron_memory"])
    File.mkdir_p!(memory_dir)
    own = Path.join(memory_dir, "job-a.md")
    other = Path.join(memory_dir, "job-b.md")
    config = Path.join([home, ".lemon", "config.toml"])
    File.write!(own, "# a\n")
    File.write!(other, "# b\n")
    File.write!(config, "[runtime]\n")
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)

    previous_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, Keyword.put(previous_paths || [], :home_dir, home))

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    calls = [
      {"write", %{"path" => own, "content" => "# a\nfinding\n"}},
      {"write", %{"path" => other, "content" => "# tampered\n"}},
      {"write", %{"path" => config, "content" => "[evil]\n"}}
    ]

    run_ref = make_ref()

    {:ok, _runner} =
      SessionRunner.start_link(
        request:
          request(cwd, %{cron_memory_file: own}, LemonCore.ToolPolicy.custom(deny: ["bash"])),
        opts: %{stream_fn: calls_then_finish(calls)},
        sink_pid: self(),
        run_ref: run_ref
      )

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 10_000
    assert File.read!(own) == "# a\nfinding\n"
    assert File.read!(other) == "# b\n"
    assert File.read!(config) == "[runtime]\n"
  end

  defp assert_refused(request) do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, :cwd_identity_mismatch} =
               SessionRunner.start_link(
                 request: request,
                 opts: %{stream_fn: stream_fn("must not run")},
                 sink_pid: self(),
                 run_ref: make_ref()
               )
    after
      Process.flag(:trap_exit, previous)
    end

    refute_received {:engine_event, _, %{__event__: :started}}
  end

  defp identity(path) do
    stat = File.stat!(path)
    %{"major" => stat.major_device, "minor" => stat.minor_device, "inode" => stat.inode}
  end

  # First model turn: runs `before` (after the session started), then asks for
  # a `write` of `marker.txt` relative to the working directory. Then finishes.
  defp write_then_finish(before) do
    {:ok, turns} = Agent.start_link(fn -> 0 end)

    fn model, context, options ->
      case Agent.get_and_update(turns, &{&1, &1 + 1}) do
        0 ->
          before.()

          call = %ToolCall{
            type: :tool_call,
            id: "write-marker",
            name: "write",
            arguments: %{"path" => "marker.txt", "content" => "written"}
          }

          {:ok, respond(%{message("") | content: [call], stop_reason: :tool_use})}

        _ ->
          stream_fn("done").(model, context, options)
      end
    end
  end

  # First model turn: all `calls` ({tool, arguments}) at once. Then finishes.
  defp calls_then_finish(calls) do
    {:ok, turns} = Agent.start_link(fn -> 0 end)

    fn model, context, options ->
      case Agent.get_and_update(turns, &{&1, &1 + 1}) do
        0 ->
          content =
            calls
            |> Enum.with_index()
            |> Enum.map(fn {{name, arguments}, index} ->
              %ToolCall{type: :tool_call, id: "call-#{index}", name: name, arguments: arguments}
            end)

          {:ok, respond(%{message("") | content: content, stop_reason: :tool_use})}

        _ ->
          stream_fn("done").(model, context, options)
      end
    end
  end

  defp respond(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, %{response | content: []}})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn {call, idx} ->
        LemonAi.EventStream.push(stream, {:tool_call_start, idx, %{call | arguments: %{}}})
        LemonAi.EventStream.push(stream, {:tool_call_end, idx, call})
      end)

      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  defp request(cwd, meta, tool_policy \\ nil) do
    %ExecutionRequest{
      run_id: "run-cwd-identity-#{System.unique_integer([:positive])}",
      session_key: "test:lemon:#{System.unique_integer([:positive])}",
      prompt: "hello",
      images: [],
      cwd: cwd,
      tool_policy: tool_policy,
      meta: Map.merge(%{model: model()}, meta)
    }
  end

  defp model do
    %Model{
      id: "mock-model-1",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 2,
        cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
      },
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp stream_fn(text) do
    fn _model, _context, _options ->
      response = message(text)

      {:ok, stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        LemonAi.EventStream.push(stream, {:start, %{response | content: []}})
        LemonAi.EventStream.push(stream, {:text_start, 0})
        LemonAi.EventStream.push(stream, {:text_delta, 0, text})
        LemonAi.EventStream.push(stream, {:text_end, 0, text})
        LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
        LemonAi.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end
end

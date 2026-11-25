defmodule LemonSkills.LearningNudgeTest do
  use ExUnit.Case, async: false

  alias LemonSkills.LearningNudge
  alias LemonSkills.TestSupport.LearningNudgeConfig

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))

    on_exit(fn ->
      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    cwd = Path.join(tmp_dir, "project")
    File.mkdir_p!(cwd)
    LearningNudgeConfig.isolate!(tmp_dir)
    server = start_supervised!({LearningNudge, name: nil})
    session = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(session, :stop) end)
    request = %{session_scope: :main, session_pid: session, cwd: cwd}
    %{server: server, request: request}
  end

  test "a project config.toml cannot speed up or re-enable reminders", ctx do
    configure(ctx, %{"enabled" => false})

    LearningNudgeConfig.put_project!(ctx.request.cwd, %{
      "enabled" => true,
      "memory_turn_interval" => 1
    })

    for _ <- 1..12, do: assert(turn(ctx) == :skip)

    configure(ctx, %{})
    for _ <- 1..9, do: assert(turn(ctx) == :skip)
    assert {:ok, _} = turn(ctx)
  end

  test "a project config.toml can lengthen the interval or turn reminders off", ctx do
    configure(ctx, %{"memory_turn_interval" => 2})
    LearningNudgeConfig.put_project!(ctx.request.cwd, %{"memory_turn_interval" => 4})

    for _ <- 1..3, do: assert(turn(ctx) == :skip)
    assert {:ok, _} = turn(ctx)

    LearningNudgeConfig.put_project!(ctx.request.cwd, %{"enabled" => false})
    for _ <- 1..12, do: assert(turn(ctx) == :skip)
  end

  test "learning_nudge left in skills.json is no longer read", ctx do
    path = LemonSkills.Config.global_config_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"learning_nudge": {"memory_turn_interval": 1}}))
    configure(ctx, %{})

    for _ <- 1..9, do: assert(turn(ctx) == :skip)
    assert {:ok, _} = turn(ctx)
  end

  test "default memory reminder appears on turn ten and repeats periodically", ctx do
    for _ <- 1..9, do: assert(turn(ctx) == :skip)
    assert {:ok, section} = turn(ctx)
    assert section.placement == :user_message
    assert section.body =~ "durable facts/preferences with remember"
    refute section.body =~ "skill_manage"
    assert byte_size(section.title) + byte_size(section.body) < 512
    for _ <- 1..9, do: assert(turn(ctx) == :skip)
    assert {:ok, _} = turn(ctx)
  end

  test "remember dispatch resets the memory interval even before run completion", ctx do
    configure(ctx, %{"memory_turn_interval" => 3})
    assert turn(ctx) == :skip
    assert turn(ctx) == :skip
    dispatch(ctx, "remember")
    assert turn(ctx) == :skip
    assert turn(ctx) == :skip
    assert {:ok, section} = turn(ctx)
    assert section.body =~ "remember"
  end

  test "fifteen calls in the previous completed run trigger a one-turn skill reminder", ctx do
    assert turn(ctx) == :skip
    for _ <- 1..14, do: dispatch(ctx, "read")
    complete(ctx)
    assert turn(ctx) == :skip
    for _ <- 1..15, do: dispatch(ctx, "read")
    complete(ctx)
    assert {:ok, section} = turn(ctx)
    assert section.body =~ "create or patch a skill with skill_manage"
    assert turn(ctx) == :skip
  end

  test "skill_manage anywhere in the previous run suppresses its skill reminder", ctx do
    assert turn(ctx) == :skip
    dispatch(ctx, "skill_manage")
    for _ <- 1..16, do: dispatch(ctx, "read")
    complete(ctx)
    assert turn(ctx) == :skip
    for _ <- 1..15, do: dispatch(ctx, "read")
    complete(ctx)
    assert {:ok, %{body: body}} = turn(ctx)
    assert body =~ "skill_manage"
  end

  test "config controls both thresholds and combines fixed reminders", ctx do
    configure(ctx, %{"memory_turn_interval" => 2, "skill_tool_threshold" => 2})
    assert turn(ctx) == :skip
    dispatch(ctx, "untrusted tool name with secret input")
    dispatch(ctx, "read")
    complete(ctx)
    assert {:ok, %{body: body}} = turn(ctx)
    assert body =~ "remember"
    assert body =~ "skill_manage"
    refute body =~ "untrusted tool name"
  end

  test "disabled config injects nothing and forgets prior counters", ctx do
    configure(ctx, %{"memory_turn_interval" => 2})
    assert turn(ctx) == :skip
    configure(ctx, %{"enabled" => false, "memory_turn_interval" => 2})
    for _ <- 1..3, do: assert(turn(ctx) == :skip)
    configure(ctx, %{"memory_turn_interval" => 2})
    assert turn(ctx) == :skip
    assert {:ok, _} = turn(ctx)
  end

  test "subagents neither receive reminders nor reset main counters", ctx do
    configure(ctx, %{"memory_turn_interval" => 2, "skill_tool_threshold" => 1})
    sub = put_in(ctx.request.session_scope, :subagent)
    for _ <- 1..3, do: assert(turn(sub) == :skip)
    assert turn(ctx) == :skip
    dispatch(sub, "remember")
    dispatch(sub, "read")
    complete(sub)
    assert {:ok, %{body: body}} = turn(ctx)
    assert body =~ "remember"
    refute body =~ "skill_manage"

    assert LearningNudge.contribute(%{session_pid: ctx.request.session_pid}, server: ctx.server) ==
             :skip
  end

  test "separate session processes never share counters", ctx do
    configure(ctx, %{"memory_turn_interval" => 2})
    other = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(other, :stop) end)
    assert turn(ctx) == :skip
    assert turn(put_in(ctx.request.session_pid, other)) == :skip
    assert {:ok, _} = turn(ctx)
  end

  test "internal followups neither tick turns nor consume the previous run's reminder", ctx do
    configure(ctx, %{"memory_turn_interval" => 2, "skill_tool_threshold" => 1})
    assert turn(ctx) == :skip
    dispatch(ctx, "read")
    complete(ctx)
    internal = put_in(ctx.request[:user_turn], false)
    for _ <- 1..3, do: assert(turn(internal) == :skip)
    assert {:ok, %{body: body}} = turn(ctx)
    assert body =~ "remember"
    assert body =~ "skill_manage"
  end

  test "session death removes volatile bookkeeping", ctx do
    assert turn(ctx) == :skip
    target = self()

    :ok =
      :sys.install(ctx.server, {
        fn
          notify, {:in, {:DOWN, _, :process, _, _}}, _ ->
            send(notify, :session_down_observed)
            notify

          notify, _, _ ->
            notify
        end,
        target
      })

    send(ctx.request.session_pid, :stop)
    assert_receive :session_down_observed
    # The trace notification precedes handling, so this call is the barrier.
    assert map_size(:sys.get_state(ctx.server).sessions) == 0
  end

  defp turn(ctx), do: LearningNudge.contribute(ctx.request, server: ctx.server)

  defp configure(ctx, settings),
    do: LearningNudgeConfig.put_operator!(ctx.request.cwd, settings)

  defp dispatch(ctx, name) do
    :telemetry.execute(
      [:coding_agent, :session, :tool_dispatched],
      %{},
      Map.put(Map.take(ctx.request, [:session_pid, :session_scope]), :tool_name, name)
    )
  end

  defp complete(ctx) do
    :telemetry.execute(
      [:coding_agent, :session, :run_completed],
      %{},
      Map.take(ctx.request, [:session_pid, :session_scope])
    )
  end
end

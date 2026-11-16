defmodule CodingAgent.Session.LiveRootSessionsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Executor, Session, SessionManager, SessionRegistry}
  alias CodingAgent.Session.RootLifecycle
  alias LemonAgent.Test.Mocks
  alias LemonCore.ResumeToken
  alias LemonGateway.ExecutionRequest

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    observer = self()
    {:ok, events} = Agent.start(fn -> %{} end)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [
          [:coding_agent, :session, :journal_load],
          [:coding_agent, :session, :environment_capture]
        ],
        fn event, %{count: count}, %{session_id: id}, table ->
          Agent.update(
            table,
            &Map.update(&1, {id, List.last(event)}, count, fn n -> n + count end)
          )
        end,
        events
      )

    stream = fn model, context, options ->
      send(observer, {:provider, self(), context, options})

      receive do
        {:respond, text} ->
          Mocks.mock_stream_fn_single(Mocks.assistant_message(text)).(model, context, options)
      after
        5_000 -> raise "live root provider was not released"
      end
    end

    on_exit(fn ->
      :telemetry.detach(handler)
      Agent.stop(events)
      File.rm_rf!(SessionManager.get_session_dir(cwd))
    end)

    %{stream: stream, events: events}
  end

  test "a pending prompt timer refuses root checkout and retention without treating its ref as a boolean" do
    state = %Session{is_streaming: false, pending_prompt_timer_ref: make_ref()}

    assert {:reply, {:error, :session_busy}, ^state} =
             Session.handle_call({:prepare_root_turn, []}, {self(), make_ref()}, state)

    assert {:reply, {:error, :session_busy}, retaining} =
             Session.handle_call({:retain_root, 0}, {self(), make_ref()}, state)

    assert retaining == %{state | root_retention_ttl: 0}
  end

  test "a second turn reuses the live owner without journal loads or environment captures", ctx do
    {first, session, id} = start_turn(ctx, "first")
    assert_receive {:provider, provider, _context, _options}, 5_000
    send(provider, {:respond, "complete prior answer"})
    complete(first)

    assert counts(ctx.events, id) == %{journal_load: 0, environment_capture: 1}
    assert Process.alive?(session)
    first_agent = Session.get_state(session).agent

    assert {:error, :not_session_owner} =
             Session.validate_live_execution_options(
               [cwd: ctx.tmp_dir],
               Session.get_state(session).session_manager
             )

    {second, same_session, ^id} = start_turn(ctx, "second", id)
    assert same_session == session
    assert Session.get_state(session).agent == first_agent
    assert_receive {:provider, provider, context, _options}, 5_000
    assert Enum.any?(context.messages, &(Map.get(&1, :role) == :assistant))
    send(provider, {:respond, "second answer"})
    complete(second)

    # The synchronous owner read is a mailbox barrier before reading counters.
    assert Session.get_state(session).root_idle_token
    assert counts(ctx.events, id) == %{journal_load: 0, environment_capture: 1}
  end

  test "TTL parking restores the journal once and does not recapture its environment", ctx do
    {first, session, id} = start_turn(ctx, "before parking")
    assert_receive {:provider, provider, before_parking, _}, 5_000
    send(provider, {:respond, "saved before parking"})
    complete(first)
    ref = Process.monitor(session)

    # Zero TTL uses the production timer path, not a sleep or a polling race.
    assert :ok = GenServer.call(session, {:retain_root, 0})
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
    assert :error = SessionRegistry.lookup(id)

    {second, restored, ^id} = start_turn(ctx, "after parking", id)
    refute restored == session
    assert_receive {:provider, provider, context, _}, 5_000
    assert context.system_prompt == before_parking.system_prompt
    assert Enum.any?(context.messages, &assistant_text?(&1, "saved before parking"))
    send(provider, {:respond, "restored answer"})
    complete(second)
    assert Session.get_state(restored).root_idle_token
    assert counts(ctx.events, id) == %{journal_load: 1, environment_capture: 1}
  end

  test "oldest idle roots are evicted, never running roots, and stale TTL messages cannot park a turn",
       ctx do
    assert RootLifecycle.idle_ttl_ms() == 300_000
    assert RootLifecycle.max_idle_roots() == 32

    {first, oldest, id} = start_turn(ctx, "oldest")
    assert_receive {:provider, provider, _, _}, 5_000
    send(provider, {:respond, "oldest answer"})
    complete(first)
    token = Session.get_state(oldest).root_idle_token

    {second, active, ^id} = start_turn(ctx, "active", id)
    assert active == oldest
    assert_receive {:provider, provider, _, _}, 5_000
    send(active, {:park_root, token})
    assert Session.get_state(active).is_streaming

    idle =
      for index <- 1..3 do
        {run, session, _id} = start_turn(ctx, "idle-#{index}")
        assert_receive {:provider, idle_provider, _, _}, 5_000
        send(idle_provider, {:respond, "idle answer"})
        complete(run)
        assert Session.get_state(session).root_idle_token
        session
      end

    [evicted, retained_a, retained_b] = idle
    ref = Process.monitor(evicted)
    assert :ok = RootLifecycle.enforce_cap(2)
    assert_receive {:DOWN, ^ref, :process, ^evicted, :normal}, 5_000
    assert Process.alive?(retained_a)
    assert Process.alive?(retained_b)
    assert Session.get_state(active).is_streaming
    send(provider, {:respond, "active answer"})
    complete(second)
  end

  test "queued auto-resume cannot overtake the terminal persistence barrier", ctx do
    {first, session, id} = start_turn(ctx, "first queued turn")
    assert_receive {:provider, provider, _, _}, 5_000
    gate = make_ref()
    observer = self()

    # Pause the real owner after broadcasting the terminal event but before
    # returning from its callback. Completion must wait for its queued save call.
    hook = fn
      :waiting, {:noreply, state}, _extra ->
        if match?(%Session{terminal_event: {:agent_end, _}}, state) do
          send(observer, {:terminal_owner_paused, self()})

          receive do
            {^gate, :release} -> :released
          after
            5_000 -> raise "terminal owner was not released"
          end
        else
          :waiting
        end

      status, _event, _extra ->
        status
    end

    :ok = :sys.install(session, {hook, :waiting})
    on_exit(fn -> send(session, {gate, :release}) end)
    send(provider, {:respond, "the complete terminal answer"})
    assert_receive {:terminal_owner_paused, ^session}, 5_000
    refute_receive {:engine_event, ^first, %{__event__: :completed}}, 0
    send(session, {gate, :release})
    complete(first)

    # This models the gateway launching its queued auto-resume immediately on
    # the completion event, without waiting for the old runner to terminate.
    {second, ^session, ^id} = start_turn(ctx, "queued followup", id, :auto)
    assert_receive {:provider, provider, context, _}, 5_000
    assert Enum.any?(context.messages, &assistant_text?(&1, "the complete terminal answer"))
    send(provider, {:respond, "queued answer"})
    complete(second)
  end

  test "code reload refreshes a retained registered root in place", ctx do
    {run, session, id} = start_turn(ctx, "before reload")
    assert_receive {:provider, provider, _, _}, 5_000
    send(provider, {:respond, "before reload answer"})
    complete(run)
    old_agent = Session.get_state(session).agent

    assert %{refreshed: 1, busy: 0, failed: 0} = CodingAgent.CodeReload.refresh_sessions([id])
    assert {:ok, ^session} = SessionRegistry.lookup(id)
    assert Session.get_state(session).agent == old_agent
    assert counts(ctx.events, id) == %{journal_load: 0, environment_capture: 1}
  end

  test "finalizing an old runner leaves an acknowledged follow-up alive", ctx do
    {first, session, id} = start_turn(ctx, "initial turn")
    assert_receive {:provider, provider, _, _}, 5_000
    send(provider, {:respond, "initial answer"})
    complete(first)

    unsubscribe = Session.subscribe(session)
    assert :ok = Session.follow_up(session, "accepted next turn", id: "retained-follow-up")
    assert_receive {:provider, provider, context, _}, 5_000
    assert Enum.count(context.messages, &(Map.get(&1, :id) == "retained-follow-up")) == 1

    runner_state = %{session: session}
    assert CodingAgent.Session.Presentation.finalize_session(runner_state, true) == runner_state
    assert Process.alive?(session)
    assert Session.get_state(session).is_streaming

    assert is_reference(Session.get_state(session).root_idle_waiter)
    observer = self()

    hook = fn
      :waiting, {:noreply, %Session{root_idle_token: token}}, _extra when is_integer(token) ->
        send(observer, {:root_retained, self()})
        :retained

      status, _event, _extra ->
        status
    end

    :ok = :sys.install(session, {hook, :waiting})

    send(provider, {:respond, "follow-up answer"})
    assert_receive {:session_event, ^id, {:agent_end, _}, _}, 5_000
    assert_receive {:root_retained, ^session}, 5_000
    assert Session.get_state(session).root_idle_token
    unsubscribe.()
  end

  test "root checkout and parking fence Agent work before its events reach Session", ctx do
    {run, session, id} = start_turn(ctx, "active invocation")
    assert_receive {:provider, provider, _, _}, 5_000
    state = Session.get_state(session)
    token = System.unique_integer([:positive, :monotonic])

    # Reproduce the owner view after the previous terminal event and before the
    # queued run's agent_start: the Agent is active but Session still looks idle.
    :sys.replace_state(session, &%{&1 | is_streaming: false, root_idle_token: token})

    assert {:error, :session_busy} = RootLifecycle.checkout(id, [])
    assert :ok = GenServer.call(session, {:park_root, token})
    send(session, {:park_root, token})
    assert Session.get_state(session).run_id == state.run_id
    assert Process.alive?(session)

    :sys.replace_state(session, &%{&1 | is_streaming: true, root_idle_token: nil})
    send(provider, {:respond, "same invocation answer"})
    complete(run)
  end

  defp start_turn(ctx, prompt, id \\ nil, source \\ :explicit) do
    request = %ExecutionRequest{
      run_id: "live-root-#{System.unique_integer([:positive, :monotonic])}",
      session_key: "agent:live-root-#{Path.basename(ctx.tmp_dir)}:main",
      prompt: prompt,
      cwd: ctx.tmp_dir,
      images: [],
      resume: if(id, do: ResumeToken.new("lemon", id)),
      meta: %{
        model: Mocks.mock_model(),
        resume_source: source,
        project_memory_capture: false
      }
    }

    assert {:ok, run_ref, %{runner_pid: runner}} =
             Executor.start_run(request, %{stream_fn: ctx.stream}, self())

    session = :sys.get_state(runner).session
    id = Session.get_state(session).session_manager.header.id

    on_exit(fn ->
      monitor = Process.monitor(session)
      CodingAgent.Session.Presentation.safe_stop_session(session)
      assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 5_000
    end)

    {run_ref, session, id}
  end

  defp complete(run_ref) do
    receive do
      {:engine_event, ^run_ref, %{__event__: :completed, ok: true}} -> :ok
      {:engine_event, ^run_ref, %{__event__: :completed} = event} -> flunk(inspect(event))
    after
      5_000 -> flunk("live root did not complete")
    end
  end

  defp counts(recorder, id) do
    Agent.get(recorder, fn counters ->
      Map.new([:journal_load, :environment_capture], fn event ->
        {event, Map.get(counters, {id, event}, 0)}
      end)
    end)
  end

  defp assistant_text?(%{role: :assistant, content: content}, text),
    do: Enum.any?(content, &(Map.get(&1, :text) == text))

  defp assistant_text?(_message, _text), do: false
end

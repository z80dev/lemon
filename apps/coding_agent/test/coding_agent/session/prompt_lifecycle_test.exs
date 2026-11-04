defmodule CodingAgent.Session.PromptLifecycleTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.Session.{CompactionLifecycle, CompactionManager, Persistence}
  alias CodingAgent.SessionManager
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    owner = self()
    calls = start_supervised!({Agent, fn -> 0 end})
    response = Mocks.mock_stream_fn_single(Mocks.assistant_message("completed B"))

    stream_fn = fn model, context, options ->
      Agent.update(calls, &(&1 + 1))
      send(owner, {:provider_called, self(), context})

      receive do
        :release -> response.(model, context, options)
      end
    end

    session =
      start_supervised!(
        {Session,
         cwd: tmp_dir,
         workspace_dir: Path.join(tmp_dir, "workspace"),
         model: Mocks.mock_model(),
         settings_manager: %CodingAgent.SettingsManager{compaction_enabled: false},
         tools: [],
         extension_inventory: {[], []},
         mcp_tools: [],
         stream_fn: stream_fn}
      )

    Session.subscribe(session)
    %{session: session, calls: calls}
  end

  for cancellation <- [:abort, :reset],
      producer <- [:prompt, :async_followup, :parent_question],
      stage <- [:scheduled, :dispatch, :compaction_resume] do
    @tag lifecycle_cancellation: cancellation,
         lifecycle_producer: producer,
         lifecycle_stage: stage
    test "#{cancellation} rejects stale #{stage} from #{producer} without consuming the next prompt",
         %{
           session: session,
           calls: calls,
           lifecycle_cancellation: cancellation,
           lifecycle_producer: producer,
           lifecycle_stage: stage
         } do
      old_id = Session.get_state(session).session_manager.header.id
      old_prompt = hold_prompt(session, producer, "prompt-A")
      {delayed, task} = hold_stage(session, old_prompt, stage)

      case cancellation do
        :abort -> assert :ok = Session.abort(session)
        :reset -> assert :ok = Session.reset(session)
      end

      reason = if cancellation == :abort, do: :assistant_aborted, else: :reset
      assert_receive {:session_event, ^old_id, {:canceled, ^reason}}, 2_000
      assert Session.get_state(session).pending_prompt == nil
      assert Agent.get(calls, & &1) == 0
      assert_task_stopped(task)

      current_prompt = hold_prompt(session, producer, "prompt-B")
      {:do_prompt, old_ref, _, _} = old_prompt
      {:do_prompt, current_ref, _, _} = current_prompt
      refute old_ref == current_ref
      before = Session.get_state(session)

      send(session, delayed)
      send_stale_task_messages(session, task)
      # Two calls also drain a dispatch a broken do_prompt handler might enqueue.
      Session.get_state(session)
      assert Session.get_state(session) == before
      assert LemonAgent.Agent.get_state(before.agent).messages == []
      assert Agent.get(calls, & &1) == 0
      refute_received {:session_event, _, {:agent_start}}

      send(session, current_prompt)
      assert_receive {:provider_called, worker, context}, 2_000
      user_texts = user_texts(context.messages)
      assert Enum.count(user_texts, &String.contains?(&1, "prompt-B")) == 1
      refute Enum.any?(user_texts, &String.contains?(&1, "prompt-A"))
      send(worker, :release)
      assert_receive {:session_event, _, {:agent_end, _}}, 2_000

      send(session, delayed)
      send(session, current_prompt)
      Session.get_state(session)
      finished = Session.get_state(session)
      assert finished.pending_prompt == nil
      refute finished.is_streaming
      assert Agent.get(calls, & &1) == 1

      assert :ok = Session.save(session)
      assert {:ok, saved} = SessionManager.load_from_file(finished.session_file)
      saved_texts = saved |> Persistence.restore_messages_from_session() |> user_texts()
      assert Enum.count(saved_texts, &String.contains?(&1, "prompt-B")) == 1

      # Async completions are intentionally persisted on admission, even if canceled.
      if producer != :async_followup or cancellation == :reset do
        refute Enum.any?(saved_texts, &String.contains?(&1, "prompt-A"))
      end
    end
  end

  for completion <- [:result, :timeout, :down] do
    @tag lifecycle_completion: completion
    test "the current prompt resumes once after compaction #{completion}", %{
      session: session,
      calls: calls,
      lifecycle_completion: completion
    } do
      prompt = hold_prompt(session, :prompt, "prompt-B")
      {dispatch, task} = hold_stage(session, prompt, :compaction_resume)

      case completion do
        :result ->
          send(session, {:auto_compaction_result, task.compaction.signature, {:error, :failed}})
          Session.get_state(session)
          send(task.worker, :stop)

        :timeout ->
          send(session, {:auto_compaction_task_timeout, task.compaction.task_monitor_ref})

        :down ->
          Process.exit(task.worker, :kill)
      end

      assert_receive {:provider_called, worker, context}, 2_000
      assert user_texts(context.messages) == ["prompt-B"]
      assert_task_stopped(task)
      send(session, dispatch)
      send(session, prompt)
      state = Session.get_state(session)
      assert state.pending_prompt == nil
      refute state.auto_compaction.in_progress
      assert Agent.get(calls, & &1) == 1
      send(worker, :release)
      assert_receive {:session_event, _, {:agent_end, _}}, 2_000
    end
  end

  test "agent exit invalidates a deferred prompt and releases its compaction worker", %{
    session: session,
    calls: calls
  } do
    prompt = hold_prompt(session, :prompt, "prompt-A")
    {delayed, task} = hold_stage(session, prompt, :compaction_resume)
    agent = Session.get_state(session).agent
    monitor = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^agent, :killed}, 2_000
    # The worker only exits after the Session handles the linked agent's exit.
    assert_task_stopped(task)

    send(session, delayed)
    send(session, prompt)
    send_stale_task_messages(session, task)
    state = Session.get_state(session)
    assert state.pending_prompt == nil
    refute state.is_streaming
    refute state.auto_compaction.in_progress
    assert Agent.get(calls, & &1) == 0
  end

  # Hold the real public request at the mailbox boundary. Its production handler
  # still runs in the Session process, and we retain its actual scheduled message
  # before the GenServer can dispatch it. No race against the deferral timer.
  defp hold_prompt(session, producer, text) do
    owner = self()
    barrier = make_ref()

    holder =
      Task.async(fn ->
        :sys.replace_state(session, fn state ->
          send(owner, {:admission_ready, barrier})

          receive do
            {:"$gen_call", from, request} ->
              {:reply, :ok, state} = Session.handle_call(request, from, state)
              GenServer.reply(from, :ok)
              %{ref: prompt_ref} = state.pending_prompt

              receive do
                {:do_prompt, ^prompt_ref, _, _} = prompt ->
                  send(owner, {:held_prompt, barrier, prompt})
                  state
              after
                2_000 -> raise "deferred prompt was not scheduled"
              end
          after
            2_000 -> raise "prompt admission did not arrive"
          end
        end)
      end)

    assert_receive {:admission_ready, ^barrier}, 2_000

    result =
      case producer do
        :prompt -> Session.prompt(session, text)
        :async_followup -> Session.handle_async_followup(session, text)
        :parent_question -> Session.deliver_parent_question(session, text)
      end

    assert :ok = result

    Task.await(holder)
    assert_receive {:held_prompt, ^barrier, prompt}, 2_000
    prompt
  end

  defp hold_stage(_session, prompt, :scheduled), do: {prompt, nil}

  defp hold_stage(session, {:do_prompt, prompt_ref, _, _} = prompt, :dispatch) do
    owner = self()

    :sys.replace_state(session, fn state ->
      {:noreply, state} = Session.handle_info(prompt, state)

      receive do
        {:dispatch_prompt, ^prompt_ref, _, _} = dispatch ->
          send(owner, {:held_dispatch, dispatch})
          state
      after
        2_000 -> raise "prompt dispatch was not scheduled"
      end
    end)

    assert_receive {:held_dispatch, dispatch}
    {dispatch, nil}
  end

  defp hold_stage(session, {:do_prompt, prompt_ref, message, system_prompt}, :compaction_resume) do
    owner = self()

    worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(worker)
    on_exit(fn -> if Process.alive?(worker), do: Process.exit(worker, :kill) end)

    state =
      :sys.replace_state(session, fn state ->
        task_monitor = Process.monitor(worker)

        timeout =
          Process.send_after(self(), {:auto_compaction_task_timeout, task_monitor}, 60_000)

        state = %{
          state
          | auto_compaction: %CompactionLifecycle.State{
              in_progress: true,
              signature: CompactionManager.session_signature(state),
              task_pid: worker,
              task_monitor_ref: task_monitor,
              task_timeout_ref: timeout,
              pending_prompt: {prompt_ref, message, system_prompt}
            }
        }

        state = CompactionLifecycle.resume_pending_prompt(state)

        receive do
          {:dispatch_prompt, ^prompt_ref, _, _} = dispatch ->
            send(owner, {:held_dispatch, dispatch})
            state
        after
          2_000 -> raise "compaction resume was not scheduled"
        end
      end)

    assert_receive {:held_dispatch, dispatch}

    {dispatch,
     %{session: session, worker: worker, monitor: monitor, compaction: state.auto_compaction}}
  end

  defp assert_task_stopped(nil), do: :ok

  defp assert_task_stopped(%{
         session: session,
         worker: worker,
         monitor: monitor,
         compaction: compaction
       }) do
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
    # A worker may die before its owner has finished clearing monitors and timers.
    state = Session.get_state(session)
    assert Process.read_timer(compaction.task_timeout_ref) == false
    assert state.auto_compaction.task_monitor_ref == nil
    assert state.auto_compaction.task_timeout_ref == nil
  end

  defp send_stale_task_messages(_session, nil), do: :ok

  defp send_stale_task_messages(session, %{compaction: compaction}) do
    send(session, {:auto_compaction_task_timeout, compaction.task_monitor_ref})
    send(session, {:auto_compaction_result, compaction.signature, {:error, :late_result}})
  end

  defp user_texts(messages) do
    messages
    |> CodingAgent.Messages.to_llm()
    |> Enum.filter(&(&1.role == :user))
    |> Enum.map(fn
      %{content: text} when is_binary(text) -> text
      %{content: blocks} -> Enum.map_join(blocks, "", &Map.get(&1, :text, ""))
    end)
  end
end

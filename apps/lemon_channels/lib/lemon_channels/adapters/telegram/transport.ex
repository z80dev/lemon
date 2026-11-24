defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport shell.

  The transport owns lifecycle, polling, timer receipt, and adapter-local
  runtime state, while normalized ingress flows through Telegram-local
  normalize/pipeline/action-runner helpers before router submission.
  """

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.ApprovalRequest
  alias LemonChannels.Adapters.Telegram.Transport.CallbackHandler
  alias LemonChannels.Adapters.Telegram.Transport.ChatPreferences
  alias LemonChannels.Adapters.Telegram.Transport.CommandRouter
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.FileOperations
  alias LemonChannels.Adapters.Telegram.Transport.InboundActions
  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonChannels.Adapters.Telegram.Transport.Owner

  # Fields the shell owns while a worker runs on a snapshot of the rest.
  @shell_keys [:allowed_chat_ids, :drain_paused?, :poll_task, :event_queue, :event_task]
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonChannels.Adapters.Telegram.Transport.ModelPicker
  alias LemonChannels.Adapters.Telegram.Transport.Normalize
  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Adapters.Telegram.Transport.Pipeline
  alias LemonChannels.Adapters.Telegram.Transport.Poller
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.Adapters.Telegram.Transport.RuntimeState
  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonChannels.Adapters.Telegram.Transport.TopicCommand
  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonChannels.Adapters.Telegram.Transport.VoiceHandler
  alias LemonChannels.BindingResolver
  alias LemonCore.Cwd
  alias LemonChannels.SubmissionOutcome
  alias LemonChannels.Telegram.Delivery
  alias LemonChannels.Telegram.{OffsetStore, PollerLock}
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope
  alias LemonCore.Config
  alias LemonCore.MapHelpers

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000
  @default_poller_lock_retry_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, opts), do: start_transport(opts, 0)

  defp start_transport(opts, lock_attempt) do
    base = LemonChannels.GatewayConfig.get(:telegram, %{})

    config =
      base
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    token = cfg_get(config, :bot_token)

    if is_binary(token) and token != "" do
      account_id = cfg_get(config, :account_id, "default")

      case PollerLock.acquire(account_id, token) do
        :ok ->
          :ok = TransportShared.init_dedupe()

          config_offset = cfg_get(config, :offset)
          stored_offset = OffsetStore.get(account_id, token)

          drop_pending_updates = cfg_get(config, :drop_pending_updates, false)

          # If enabled, drop any pending Telegram updates on every boot unless an explicit offset is set.
          # This prevents the bot from replying to historical messages after downtime.
          drop_pending_updates = drop_pending_updates && is_nil(config_offset)

          {openai_api_key, openai_base_url} = resolve_openai_provider()

          api_mod = resolve_api_mod(config)

          {bot_id, bot_username} =
            resolve_bot_identity(
              cfg_get(config, :bot_id),
              cfg_get(config, :bot_username),
              api_mod,
              token
            )

          state =
            RuntimeState.new(%{
              token: token,
              api_mod: api_mod,
              poll_interval_ms: config[:poll_interval_ms] || @default_poll_interval,
              dedupe_ttl_ms: config[:dedupe_ttl_ms] || @default_dedupe_ttl,
              debounce_ms: cfg_get(config, :debounce_ms, @default_debounce_ms),
              # When true, emit debug logs for inbound decisions (drops, routing, etc).
              debug_inbound: cfg_get(config, :debug_inbound, false),
              # When true, log drop/ignore reasons even if debug_inbound is false.
              log_drops: cfg_get(config, :log_drops, false),
              allow_queue_override: cfg_get(config, :allow_queue_override, false),
              allowed_chat_ids:
                RuntimeState.parse_allowed_chat_ids(cfg_get(config, :allowed_chat_ids)),
              allow_all_chats: cfg_get(config, :allow_all_chats, false) == true,
              unauthorized_dm_behavior: cfg_get(config, :unauthorized_dm_behavior, "ignore"),
              deny_unbound_chats: cfg_get(config, :deny_unbound_chats, false),
              account_id: account_id,
              voice_transcription: cfg_get(config, :voice_transcription, false),
              voice_transcription_provider:
                cfg_get(config, :voice_transcription_provider, "openai_transcribe"),
              voice_transcription_model:
                cfg_get(config, :voice_transcription_model, "gpt-4o-mini-transcribe"),
              voice_transcription_base_url:
                normalize_blank(cfg_get(config, :voice_transcription_base_url)) || openai_base_url,
              voice_transcription_api_key:
                normalize_blank(cfg_get(config, :voice_transcription_api_key)) || openai_api_key,
              voice_max_bytes: cfg_get(config, :voice_max_bytes, 10 * 1024 * 1024),
              voice_transcriber: config[:voice_transcriber] || LemonChannels.VoiceTranscriber,
              offset:
                RuntimeState.initial_offset(
                  config_offset,
                  stored_offset,
                  drop_pending_updates
                ),
              drop_pending_updates?: drop_pending_updates,
              drop_pending_done?: false,
              bot_id: bot_id,
              bot_username: bot_username,
              files: cfg_get(config, :files, %{})
            })

          log_authorization_mode(state)
          maybe_subscribe_exec_approvals()

          _ =
            start_async_task(state, fn ->
              try do
                case api_mod.set_my_commands(token, LemonChannels.CommandCatalog.telegram_menu()) do
                  {:ok, _} -> :ok
                  _ -> Logger.warning("Telegram command menu registration failed")
                end
              rescue
                _ -> Logger.warning("Telegram command menu registration failed")
              catch
                _, _ -> Logger.warning("Telegram command menu registration failed")
              end
            end)

          send(self(), :poll)
          {:noreply, state}

        {:error, :locked} ->
          retry_ms = cfg_get(config, :poller_lock_retry_ms, @default_poller_lock_retry_ms)
          await_poller_lock(opts, account_id, retry_ms, lock_attempt)
      end
    else
      {:stop, :telegram_not_configured, %{}}
    end
  end

  @impl true
  # The transport has not started polling: it has no runtime state to update.
  # The persisted allowlist is read when it acquires the lock and starts.
  def handle_call({:update_allowlist, _op, _chat_id}, _from, %{awaiting_poller_lock: true} = st),
    do: {:reply, :not_running, st}

  def handle_call(:drain_pause, _from, %{awaiting_poller_lock: true} = st) do
    if st.timer, do: Process.cancel_timer(st.timer)
    {:reply, :ok, %{st | timer: nil, drain_paused?: true}}
  end

  def handle_call({:update_allowlist, op, chat_id}, _from, state)
      when op in [:add, :remove] and is_integer(chat_id) do
    {:reply, :ok, LemonChannels.Pairing.put_allowlist("telegram", state, chat_id, op)}
  end

  # Runtime drain: stop fetching, then hand every debounced message and media
  # group to the router. The flush runs in the event worker, after whatever it
  # is doing now; the caller is answered when the flush has run. Updates not
  # yet fetched stay unconfirmed at Telegram, so the next runtime receives
  # them from the persisted offset.
  def handle_call(:drain_pause, from, state) do
    {:noreply, state |> Map.put(:drain_paused?, true) |> enqueue({:drain_flush, from})}
  end

  # Polling is an ongoing subscription, not an outbound delivery retry budget.
  # Preserve the fixed cadence on both successful and failed polls.
  defp poll_delay(state) do
    policy =
      LemonCore.Retry.policy(
        max_attempts: 2,
        base_delay_ms: state.poll_interval_ms,
        max_delay_ms: state.poll_interval_ms,
        jitter: :none
      )

    LemonCore.Retry.delay(policy, 0)
  end

  @impl true
  def handle_info(:retry_poller_lock, %{awaiting_poller_lock: true, drain_paused?: true} = st),
    do: {:noreply, st}

  def handle_info(:retry_poller_lock, %{awaiting_poller_lock: true} = st),
    do: start_transport(st.opts, st.attempt + 1)

  def handle_info(_msg, %{awaiting_poller_lock: true} = st), do: {:noreply, st}

  def handle_info(:poll, %{drain_paused?: true} = state), do: {:noreply, state}

  def handle_info(:poll, %{poll_task: %Task{}} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    case LemonCore.TaskSupervisor.async_nolink(async_supervisor_name(), fn ->
           Poller.fetch_and_prepare(state, pipeline_callbacks())
         end) do
      {:ok, task} ->
        {:noreply, Map.put(state, :poll_task, task)}

      {:error, _reason} ->
        LemonChannels.Registry.record_status("telegram", {:error, :poll_unavailable})
        Logger.warning("telegram poll task admission failed")

        Process.send_after(
          LemonChannels.Adapters.Telegram.Transport.Owner.pid(),
          :poll,
          state.poll_interval_ms
        )

        {:noreply, state}
    end
  end

  # The poll task fetched and prepared (transcribed, downloaded) the batch;
  # applying it runs in the event worker.
  def handle_info({ref, {result, prepared}}, %{poll_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = Map.delete(state, :poll_task)

    if state[:drain_paused?],
      do: {:noreply, state},
      else: {:noreply, enqueue(state, {:poll_result, result, prepared})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{poll_task: %Task{ref: ref}} = state) do
    Process.send_after(self(), :poll, poll_delay(state))
    {:noreply, Map.delete(state, :poll_task)}
  end

  def handle_info(
        {ref, {:event_done, new_state}},
        %{event_task: {%Task{ref: ref}, event}} = state
      ) do
    Process.demonitor(ref, [:flush])
    # Shell-owned fields may have changed while the worker ran; keep them.
    state = Map.merge(new_state, Map.take(state, @shell_keys)) |> Map.put(:event_task, nil)
    after_event(event, state)
    {:noreply, dispatch_next(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{event_task: {%Task{ref: ref}, event}} = state
      ) do
    LemonChannels.Registry.record_status("telegram", {:error, :event_failed})
    Logger.warning("telegram event task failed; event will not be replayed")
    state = Map.put(state, :event_task, nil)

    case event do
      {:drain_flush, from} -> GenServer.reply(from, {:error, :drain_failed})
      _ -> after_event(event, state)
    end

    {:noreply, dispatch_next(state)}
  end

  def handle_info({:telegram_bus, action, topic}, state) do
    _ = apply(LemonCore.Bus, action, [topic])
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  def handle_info(event, state) do
    if worker_event?(event),
      do: {:noreply, enqueue(state, event)},
      else: {:noreply, state}
  end

  defp worker_event?({:debounce_flush, _scope_key, _ref}), do: true
  defp worker_event?({:media_group_flush, _group_key, _ref}), do: true
  defp worker_event?({:new_session_cleanup, _sk, _chat_id, _thread_id}), do: true
  defp worker_event?({:model_picker_expired, _key, _token}), do: true

  defp worker_event?(%LemonCore.Event{type: type}),
    do: type in [:approval_requested, :run_completed]

  defp worker_event?(_event), do: false

  defp enqueue(state, event) do
    queue = :queue.in(event, Map.get(state, :event_queue, :queue.new()))
    dispatch_next(Map.put(state, :event_queue, queue))
  end

  # One event at a time, in arrival order, in a supervised worker: the shell
  # itself never performs HTTP, file or provider work.
  defp dispatch_next(state) do
    with nil <- Map.get(state, :event_task),
         {{:value, event}, queue} <- :queue.out(Map.get(state, :event_queue, :queue.new())) do
      owner = self()
      snapshot = Map.drop(state, @shell_keys -- [:allowed_chat_ids, :drain_paused?])

      case LemonCore.TaskSupervisor.async_nolink(async_supervisor_name(), fn ->
             :ok = Owner.put(owner)
             {:event_done, run_event(event, snapshot)}
           end) do
        {:ok, task} ->
          %{state | event_queue: queue} |> Map.put(:event_task, {task, event})

        {:error, _reason} ->
          LemonChannels.Registry.record_status("telegram", {:error, :event_failed})
          Logger.warning("telegram event task admission failed; event will not be replayed")
          state = Map.put(state, :event_queue, queue)

          case event do
            {:drain_flush, from} -> GenServer.reply(from, {:error, :drain_failed})
            _ -> after_event(event, state)
          end

          dispatch_next(state)
      end
    else
      _busy_or_empty -> state
    end
  end

  # The next fetch starts only after a batch was applied (it advances offset).
  defp after_event({:poll_result, _result, _prepared}, state),
    do: Process.send_after(self(), :poll, poll_delay(state))

  defp after_event(_event, _state), do: :ok

  defp run_event({:poll_result, result, prepared}, state) do
    if state[:drain_paused?],
      do: state,
      else: Poller.apply_result(state, result, pipeline_callbacks(), prepared)
  end

  defp run_event({:drain_flush, from}, state) do
    state =
      Enum.reduce(state.buffers, state, fn {key, buffer}, acc ->
        dispatch_transport_event({:debounce_flush, key, buffer.debounce_ref}, acc)
      end)

    state =
      Enum.reduce(state.media_groups, state, fn {key, group}, acc ->
        dispatch_transport_event({:media_group_flush, key, group.debounce_ref}, acc)
      end)

    GenServer.reply(from, :ok)
    state
  end

  defp run_event({:debounce_flush, _scope_key, _ref} = event, state),
    do: dispatch_transport_event(event, state)

  defp run_event({:media_group_flush, _group_key, _ref} = event, state),
    do: dispatch_transport_event(event, state)

  defp run_event(%LemonCore.Event{type: :approval_requested, payload: payload}, state),
    do: dispatch_transport_event({:approval_requested, payload}, state)

  defp run_event({:model_picker_expired, key, token}, state),
    do: ModelPicker.expire_model_picker(state, key, token)

  # Best-effort second pass to clear chat state in case a late write races with the first delete.
  defp run_event({:new_session_cleanup, session_key, chat_id, thread_id}, state) do
    _ = safe_delete_chat_state(session_key)
    _ = safe_delete_selected_resume(state, chat_id, thread_id)
    _ = safe_sweep_thread_message_indices(state, chat_id, thread_id, :all)
    state
  end

  # /new triggers an internal "memory reflection" run; only clear auto-resume after it completes.
  defp run_event(%LemonCore.Event{type: :run_completed, meta: meta} = event, state) do
    run_id = (meta || %{})[:run_id] || (meta || %{})["run_id"]
    session_key = (meta || %{})[:session_key] || (meta || %{})["session_key"]

    # Check if this is a /new command run first
    state =
      case run_id && Map.get(state.pending_new, run_id) do
        %{
          session_key: sk,
          chat_id: chat_id,
          thread_id: thread_id,
          user_msg_id: user_msg_id
        } = pending ->
          _ = safe_delete_chat_state(sk)
          _ = safe_delete_selected_resume(state, chat_id, thread_id)
          _ = safe_clear_thread_message_indices(state, chat_id, thread_id)

          # Store writes are async; do a second delete shortly after to win races.
          Process.send_after(
            LemonChannels.Adapters.Telegram.Transport.Owner.pid(),
            {:new_session_cleanup, sk, chat_id, thread_id},
            50
          )

          topic = LemonCore.Bus.run_topic(run_id)
          _ = LemonChannels.Adapters.Telegram.Transport.Owner.bus(:unsubscribe, topic)

          ok? =
            case event.payload do
              %{completed: %{ok: ok}} when is_boolean(ok) -> ok
              %{ok: ok} when is_boolean(ok) -> ok
              _ -> true
            end

          msg0 =
            if ok? do
              "Started a new session."
            else
              "Started a new session (memory recording failed)."
            end

          scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
          msg = started_new_session_message(state, scope, sk, pending[:project], msg0)

          _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)

          %{state | pending_new: Map.delete(state.pending_new, run_id)}

        _ ->
          state
      end

    # Handle reaction updates for regular runs
    state =
      case session_key && Map.get(state.reaction_runs, session_key) do
        %{
          chat_id: chat_id,
          thread_id: _thread_id,
          user_msg_id: user_msg_id
        } = _reaction_run ->
          ok? =
            case event.payload do
              %{completed: %{ok: ok}} when is_boolean(ok) -> ok
              %{ok: ok} when is_boolean(ok) -> ok
              _ -> true
            end

          # Update reaction: ✅ for success, ❌ for failure
          reaction_emoji = if ok?, do: "✅", else: "❌"

          _ =
            start_async_task(state, fn ->
              state.api_mod.set_message_reaction(
                state.token,
                chat_id,
                user_msg_id,
                reaction_emoji,
                %{is_big: true}
              )
            end)

          # Unsubscribe from session topic and remove from tracking
          topic = LemonCore.Bus.session_topic(session_key)
          _ = LemonChannels.Adapters.Telegram.Transport.Owner.bus(:unsubscribe, topic)

          %{state | reaction_runs: Map.delete(state.reaction_runs, session_key)}

        _ ->
          state
      end

    state
  end

  @impl true
  def terminate(_reason, state) do
    if task = state[:poll_task], do: Task.shutdown(task, :brutal_kill)
    with {%Task{} = task, _event} <- state[:event_task], do: Task.shutdown(task, :brutal_kill)
    if state[:token], do: PollerLock.release(state.account_id, state.token)
    :ok
  end

  # Another runtime owns this bot token. Crashing would escalate through the
  # adapter supervisors, so wait alive and retry with capped backoff instead.
  defp await_poller_lock(opts, account_id, retry_ms, attempt) do
    delay = min(LemonCore.Retry.exponential_backoff(retry_ms, min(attempt, 5)), retry_ms * 30)

    Logger.warning(
      "Telegram poller already running for account_id=#{inspect(account_id)}; retrying lock in #{delay}ms"
    )

    LemonChannels.Registry.record_status("telegram", {:error, :poller_locked})

    {:noreply,
     %{
       awaiting_poller_lock: true,
       opts: opts,
       attempt: attempt,
       drain_paused?: false,
       timer:
         Process.send_after(
           LemonChannels.Adapters.Telegram.Transport.Owner.pid(),
           :retry_poller_lock,
           delay
         )
     }}
  end

  defp dispatch_transport_event(event, state) do
    case Normalize.event(state, event) do
      {:ok, normalized} -> Pipeline.run(normalized, state, pipeline_callbacks())
      {:error, _reason} -> state
    end
  end

  defp pipeline_callbacks do
    %{
      handle_callback_query: &handle_callback_query/2,
      execute_inbound_message: &execute_inbound_message/2,
      index_known_target: &index_known_target/2,
      maybe_log_drop: &maybe_log_drop/3,
      maybe_transcribe_voice: &maybe_transcribe_voice/2,
      process_media_group: &process_media_group/2,
      persist_offset: &persist_offset/2,
      reply_whoami: &reply_whoami/2,
      send_approval_request: &send_approval_request/2,
      send_unpaired_notice: &send_unpaired_notice/2,
      start_async_task: &start_async_task/2,
      submit_buffer: &submit_buffer/2
    }
  end

  @unpaired_notice_text "This bot is not paired. Run `lemon gateway setup telegram`. " <>
                          "Send /whoami to see this chat's ID."

  defp log_authorization_mode(%{allowed_chat_ids: [_ | _]}), do: :ok

  defp log_authorization_mode(%{allow_all_chats: true, account_id: account_id}) do
    Logger.warning(
      "Telegram account_id=#{inspect(account_id)} accepts every chat " <>
        "(gateway.telegram.allow_all_chats = true); anyone who finds the bot can run the agent"
    )
  end

  defp log_authorization_mode(%{account_id: account_id}) do
    Logger.warning(
      "Telegram account_id=#{inspect(account_id)} is not paired: " <>
        "gateway.telegram.allowed_chat_ids is empty, so every chat is ignored. " <>
        "Run `lemon gateway setup telegram` to pair your chat."
    )
  end

  defp reply_whoami(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      user_id = inbound.sender && inbound.sender.id

      text =
        [
          "chat_id: #{chat_id}",
          user_id && "user_id: #{user_id}",
          thread_id && "topic_id: #{thread_id}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      send_critical_feedback(state, chat_id, thread_id, user_msg_id, text)
    end

    :ok
  end

  defp send_unpaired_notice(%{unauthorized_dm_behavior: "pair"} = state, inbound) do
    with {:ok, text} <- LemonChannels.Pairing.reply("telegram", inbound) do
      {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
      send_critical_feedback(state, chat_id, thread_id, user_msg_id, text)
    end

    :ok
  rescue
    _ -> Logger.warning("Telegram pairing reply failed")
  catch
    _kind, _reason -> Logger.warning("Telegram pairing reply failed")
  end

  defp send_unpaired_notice(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      Logger.warning(
        "Telegram dropped update from unpaired chat_id=#{chat_id}; " <>
          "run `lemon gateway setup telegram` to pair the bot"
      )

      send_critical_feedback(state, chat_id, thread_id, user_msg_id, @unpaired_notice_text)
    end

    :ok
  end

  defp execute_inbound_message(state, inbound) do
    CommandRouter.handle_inbound_message(state, inbound, %{
      bot_username: state.bot_username,
      handle_cwd_command: &handle_cwd_command/2,
      handle_checkpoint_command: &handle_checkpoint_command/2,
      handle_goal_command: &handle_goal_command/2,
      handle_kanban_command: &handle_kanban_command/2,
      handle_media_command: &handle_media_command/2,
      handle_media_auto_put: &handle_media_auto_put/2,
      handle_model_command: &ModelPicker.handle_model_command/2,
      handle_new_session: &handle_new_session/3,
      handle_remind_command: &handle_remind_command/2,
      handle_reminders_command: &handle_reminders_command/2,
      handle_unremind_command: &handle_unremind_command/2,
      handle_portable_command: &handle_portable_command/2,
      handle_resume_command: &handle_resume_command/2,
      handle_thinking_command: &handle_thinking_command/2,
      handle_topic_command: &handle_topic_command/2,
      handle_trigger_command: &handle_trigger_command/2,
      maybe_apply_selected_resume: &maybe_apply_selected_resume/3,
      maybe_cancel_by_reply: &maybe_cancel_by_reply/2,
      maybe_handle_model_picker_input: &ModelPicker.maybe_handle_model_picker_input/3,
      maybe_log_drop: &maybe_log_drop/3,
      maybe_mark_fork_when_busy: &maybe_mark_fork_when_busy/2,
      maybe_mark_new_session_pending: &maybe_mark_new_session_pending/2,
      maybe_switch_session_from_reply: &maybe_switch_session_from_reply/2,
      should_ignore_for_trigger?: &should_ignore_for_trigger?/3,
      submit_inbound_now: &submit_inbound_now/2,
      refuse_command: &refuse_admin_command/2
    })
  end

  defp refuse_admin_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          LemonChannels.CommandAuthority.refusal_message()
        )
    end

    state
  end

  defp inbound_action_callbacks do
    %{
      current_thread_generation: &current_thread_generation/3,
      extract_explicit_resume_and_strip: &extract_explicit_resume_and_strip/1,
      extract_message_ids: &extract_message_ids/1,
      maybe_index_telegram_msg_session: &maybe_index_telegram_msg_session/4,
      maybe_subscribe_to_session: &maybe_subscribe_to_session/1,
      resolve_model_hint: &resolve_model_hint/4,
      resolve_session_key: &resolve_session_key/4,
      resolve_thinking_hint: &resolve_thinking_hint/3,
      send_submission_failure: &send_critical_feedback/5,
      send_system_message: &send_system_message/5
    }
  end

  defp submit_buffer(state, buffer) do
    InboundActions.submit_buffer(state, buffer, inbound_action_callbacks())
  end

  defp submit_inbound_now(state, inbound) do
    InboundActions.execute_inbound_message(state, inbound, inbound_action_callbacks())
  end

  defp index_known_target(state, update) do
    UpdateProcessor.maybe_index_known_target(state, update)
  end

  defp maybe_cancel_by_reply(state, inbound) do
    {chat_id, thread_id} = extract_chat_ids(inbound)
    reply_to_id = inbound.message.reply_to_id || inbound.meta[:reply_to_id]

    if is_integer(chat_id) do
      scope = %LemonCore.ChatScope{
        transport: :telegram,
        chat_id: chat_id,
        topic_id: thread_id
      }

      session_key =
        case reply_to_id && Integer.parse(to_string(reply_to_id)) do
          {progress_msg_id, _} ->
            lookup_session_key_for_reply(state, scope, progress_msg_id) ||
              build_session_key(state, inbound, scope)

          _ ->
            build_session_key(state, inbound, scope)
        end

      user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)

      case LemonChannels.Runtime.cancel_session(session_key, :user_requested) do
        :ok ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Cancelling current run..."
            )

        {:error, _} = error ->
          maybe_forget_inbound_dedupe(inbound, error)

          Logger.warning(
            "telegram cancel unavailable: reason=#{SubmissionOutcome.log_label(error)}"
          )

          _ =
            send_critical_feedback(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              cancel_failure_message(error)
            )
      end
    end

    state
  end

  defp extract_explicit_resume_and_strip(text),
    do: ResumeSelection.extract_explicit_resume_and_strip(text)

  defp process_media_group(state, group) do
    items = Enum.reverse(group.items || [])
    first = List.first(items)

    if not is_map(first) do
      :ok
    else
      chat_id = first.meta[:chat_id] || parse_int(first.peer.id)
      thread_id = parse_int(first.peer.thread_id)
      user_msg_id = first.meta[:user_msg_id] || parse_int(first.message.id)

      # If any item has a /file put command caption, use that; else auto-put behavior.
      file_put =
        Enum.find(items, fn inbound ->
          txt = inbound.message.text || ""

          Commands.file_command?(txt, state.bot_username) and
            String.starts_with?(String.trim_leading(txt), "/file") and
            String.starts_with?(
              String.trim(Commands.telegram_command_args(txt, "file") || ""),
              "put"
            )
        end)

      if file_put do
        FileOperations.handle_file_put_media_group(
          state,
          file_put,
          items,
          chat_id,
          thread_id,
          user_msg_id
        )
      else
        FileOperations.handle_auto_put_media_group(state, items, chat_id, thread_id, user_msg_id)
      end
    end

    :ok
  end

  # handle_media_auto_put wraps FileOperations but needs access to
  # GenServer-level helpers (should_ignore_for_trigger?, submit_inbound_now, etc.)
  defp handle_media_auto_put(state, inbound) do
    cfg = FileOperations.files_cfg(state)
    {_chat_id, _thread_id, _user_msg_id} = extract_message_ids(inbound)

    case FileOperations.handle_media_auto_put(state, inbound) do
      {:ok, final_rel} ->
        mode = cfg_get(cfg, :auto_put_mode, "upload")
        caption = String.trim(inbound.message.text || "")

        cond do
          mode == "prompt" and caption != "" ->
            prompt = String.trim("#{caption}\n\n[uploaded: #{final_rel}]")
            inbound = %{inbound | message: Map.put(inbound.message, :text, prompt)}

            if should_ignore_for_trigger?(state, inbound, prompt) do
              state
            else
              {state, inbound} = maybe_switch_session_from_reply(state, inbound)
              inbound = maybe_apply_selected_resume(state, inbound, prompt)
              submit_inbound_now(state, inbound)
            end

          true ->
            state
        end

      {:error, _} ->
        state
    end
  end

  defp maybe_select_project_for_scope(%ChatScope{} = scope, selector) when is_binary(selector),
    do: LemonChannels.ProjectSelection.select(scope, selector)

  defp maybe_switch_session_from_reply(state, inbound) do
    ResumeSelection.maybe_switch_session_from_reply(state, inbound, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      build_session_key: &build_session_key/3,
      normalize_msg_id: &normalize_msg_id/1,
      send_system_message: &send_system_message/5,
      submit_inbound_now: &submit_inbound_now/2
    })
  end

  defp handle_resume_command(state, inbound) do
    state
    |> MessageBuffer.drop_buffer_for(inbound)
    |> ResumeSelection.handle_resume_command(inbound, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      build_session_key: &build_session_key/3,
      normalize_msg_id: &normalize_msg_id/1,
      send_system_message: &send_system_message/5,
      submit_inbound_now: &submit_inbound_now/2
    })
  end

  defp handle_new_session(state, inbound, raw_selector) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      selector = normalize_selector(raw_selector)

      project_result =
        case selector do
          nil -> :noop
          sel -> LemonChannels.ProjectSelection.resolve(sel)
        end

      case project_result do
        {:error, msg} when is_binary(msg) ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
          state

        _ ->
          start_new_session(state, inbound, scope, session_key, project_result,
            chat_id: chat_id,
            thread_id: thread_id,
            user_msg_id: user_msg_id
          )
      end
    end
  end

  defp normalize_selector(raw_selector) when is_binary(raw_selector) do
    case String.trim(raw_selector) do
      "" -> nil
      other -> other
    end
  end

  defp normalize_selector(_), do: nil

  defp start_new_session(state, inbound, scope, session_key, project_result, ids) do
    chat_id = ids[:chat_id]
    thread_id = ids[:thread_id]
    user_msg_id = ids[:user_msg_id]

    case LemonChannels.Runtime.cancel_session(session_key, :new_session) do
      :ok ->
        state = MessageBuffer.drop_buffer_for(state, inbound)
        project_result = persist_new_session_project(scope, project_result)
        project = extract_project_info(project_result)

        {previous_generation, _new_generation} = bump_thread_generation(state, chat_id, thread_id)

        # Clear selected resume only after the router accepts cancellation, so
        # a failed /new leaves the current local session state intact.
        _ = safe_delete_selected_resume(state, chat_id, thread_id)

        msg =
          started_new_session_message(
            state,
            scope,
            session_key,
            project,
            "Started a new session."
          )

        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)

        _ =
          start_async_task(state, fn ->
            run_new_session_background_work(
              state,
              inbound,
              scope,
              session_key,
              chat_id,
              thread_id,
              user_msg_id,
              previous_generation
            )
          end)

        state

      {:error, _} = error ->
        maybe_forget_inbound_dedupe(inbound, error)

        Logger.warning(
          "telegram new-session cancellation failed: reason=#{SubmissionOutcome.log_label(error)}"
        )

        _ =
          send_critical_feedback(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            new_session_failure_message(error)
          )

        state
    end
  end

  defp persist_new_session_project(_scope, :noop), do: :noop

  defp persist_new_session_project(%ChatScope{} = scope, {:ok, project}) when is_map(project) do
    LemonChannels.ProjectSelection.persist(scope, project)
  end

  defp persist_new_session_project(_scope, result), do: result

  defp run_new_session_background_work(
         state,
         inbound,
         %ChatScope{} = scope,
         session_key,
         chat_id,
         thread_id,
         user_msg_id,
         previous_generation
       ) do
    _ = safe_delete_session_model(session_key)
    _ = safe_delete_chat_state(session_key)
    _ = safe_delete_selected_resume(state, chat_id, thread_id)
    _ = safe_sweep_thread_message_indices(state, chat_id, thread_id, previous_generation)

    _ =
      submit_memory_reflection_before_new(
        state,
        inbound,
        scope,
        session_key,
        chat_id,
        thread_id,
        user_msg_id
      )

    :ok
  end

  defp maybe_subscribe_to_session(session_key) when is_binary(session_key) do
    topic = LemonCore.Bus.session_topic(session_key)
    _ = LemonChannels.Adapters.Telegram.Transport.Owner.bus(:subscribe, topic)
  end

  defp maybe_subscribe_to_run(run_id) do
    topic = LemonCore.Bus.run_topic(run_id)
    _ = LemonChannels.Adapters.Telegram.Transport.Owner.bus(:subscribe, topic)
  end

  defp started_new_session_message(
         state,
         %ChatScope{} = scope,
         session_key,
         project,
         base_msg
       )
       when is_binary(base_msg) do
    {model_hint, model_scope} =
      resolve_model_hint(state, session_key, scope.chat_id, scope.topic_id)

    {provider_hint, model_id} = split_model_hint(model_hint)
    model_value = if(is_binary(model_id) and model_id != "", do: model_id, else: model_hint)
    model_line = format_model_line(model_value, model_scope)
    {thinking_hint, thinking_scope} = resolve_thinking_hint(state, scope.chat_id, scope.topic_id)
    thinking_line = format_thinking_line(thinking_hint, thinking_scope)

    provider_line =
      if is_binary(provider_hint) and provider_hint != "" do
        provider_hint
      else
        cfg = Config.cached()
        agent = map_get(cfg, :agent) || %{}
        default_prov = map_get(agent, :default_provider) || "anthropic"
        "#{default_prov} (default)"
      end

    cwd_line = resolve_new_session_cwd(scope)
    account_line = state.account_id || "default"

    session_line =
      if(is_binary(session_key) and session_key != "", do: session_key, else: "(unavailable)")

    [
      base_msg,
      "Model: #{model_line}",
      "Thinking: #{thinking_line}",
      "Provider: #{provider_line}",
      "CWD: #{cwd_line}",
      "Account: #{account_line}",
      "Session key: #{session_line}"
    ]
    |> maybe_append_project_line(project)
    |> Enum.join("\n")
  end

  defp started_new_session_message(_state, _scope, _session_key, project, base_msg)
       when is_binary(base_msg) do
    [base_msg]
    |> maybe_append_project_line(project)
    |> Enum.join("\n")
  end

  defp split_model_hint(model_hint) when is_binary(model_hint) and model_hint != "" do
    case String.split(model_hint, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" -> {provider, model_id}
      _ -> {nil, model_hint}
    end
  end

  defp split_model_hint(_), do: {nil, nil}

  defp format_model_line(model_value, model_scope)
       when is_binary(model_value) and model_value != "" do
    case model_scope do
      :session -> "#{model_value} (session override)"
      :future -> "#{model_value} (chat/topic default)"
      _ -> model_value
    end
  end

  defp format_model_line(_model_value, _model_scope) do
    cfg = Config.cached()
    agent = map_get(cfg, :agent) || %{}
    default = map_get(agent, :default_model) || "claude-sonnet-4-20250514"
    "#{default} (default)"
  end

  defp resolve_new_session_cwd(%ChatScope{} = scope) do
    case BindingResolver.resolve_cwd(scope) do
      cwd when is_binary(cwd) and cwd != "" ->
        Path.expand(cwd)

      _ ->
        case Cwd.channel_default_cwd() do
          cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
          _ -> "(not configured)"
        end
    end
  end

  defp maybe_append_project_line(lines, %{id: id, root: root})
       when is_list(lines) and is_binary(id) and is_binary(root) do
    lines ++ ["Project: #{id} (#{root})"]
  end

  defp maybe_append_project_line(lines, _project) when is_list(lines), do: lines

  defp extract_project_info({:ok, %{id: id, root: root}}), do: %{id: id, root: root}
  defp extract_project_info(_), do: nil

  defp submit_memory_reflection_before_new(
         state,
         inbound,
         %ChatScope{} = scope,
         session_key,
         chat_id,
         thread_id,
         user_msg_id
       )
       when is_binary(session_key) do
    MemoryReflection.submit_before_new(
      state,
      inbound,
      scope,
      session_key,
      chat_id,
      thread_id,
      user_msg_id,
      %{
        maybe_subscribe_to_run: &maybe_subscribe_to_run/1,
        current_thread_generation: &current_thread_generation/3,
        maybe_put: &maybe_put/3
      }
    )
  end

  defp submit_memory_reflection_before_new(
         _state,
         _inbound,
         _scope,
         _session_key,
         _chat_id,
         _thread_id,
         _user_msg_id
       ),
       do: :skip

  defp safe_delete_chat_state(key), do: PerChatState.safe_delete_chat_state(key)

  defp safe_delete_session_model(session_key),
    do: PerChatState.safe_delete_session_model(session_key)

  defp safe_delete_selected_resume(state, chat_id, thread_id),
    do:
      PerChatState.safe_delete_selected_resume(state.account_id || "default", chat_id, thread_id)

  defp safe_clear_thread_message_indices(state, chat_id, thread_id),
    do:
      PerChatState.safe_clear_thread_message_indices(
        state.account_id || "default",
        chat_id,
        thread_id
      )

  defp maybe_forget_inbound_dedupe(inbound, error) do
    if SubmissionOutcome.retry_safe?(error) do
      (inbound.meta || %{})
      |> Map.get(:transport_dedupe_refs, [])
      |> List.wrap()
      |> Enum.each(&TransportShared.forget_dedupe/1)
    end

    :ok
  end

  defp cancel_failure_message(error) do
    if SubmissionOutcome.uncertain?(error) do
      "I couldn't confirm whether the cancellation reached the router. Check the run status before trying again."
    else
      "I couldn't cancel the current run. Please try again."
    end
  end

  defp new_session_failure_message(error) do
    if SubmissionOutcome.uncertain?(error) do
      "I couldn't confirm cancellation, so I did not reset the local session. Check the run status before trying /new again."
    else
      "I couldn't cancel the current run, so the existing session was left unchanged. Please try /new again."
    end
  end

  defp safe_sweep_thread_message_indices(state, chat_id, thread_id, max_generation),
    do:
      PerChatState.safe_sweep_thread_message_indices(
        state.account_id || "default",
        chat_id,
        thread_id,
        max_generation
      )

  defp current_thread_generation(state, chat_id, thread_id),
    do: PerChatState.current_thread_generation(state.account_id || "default", chat_id, thread_id)

  defp bump_thread_generation(state, chat_id, thread_id),
    do: PerChatState.bump_thread_generation(state.account_id || "default", chat_id, thread_id)

  defp resolve_model_hint(state, session_key, chat_id, thread_id),
    do:
      ModelPolicyAdapter.resolve_model_hint(
        state.account_id || "default",
        session_key,
        chat_id,
        thread_id
      )

  defp resolve_thinking_hint(state, chat_id, thread_id),
    do:
      ModelPolicyAdapter.resolve_thinking_hint(state.account_id || "default", chat_id, thread_id)

  defp format_thinking_line(level, source),
    do: ModelPolicyAdapter.format_thinking_line(level, source)

  defp build_session_key(state, inbound, %ChatScope{} = scope),
    do: SessionRouting.build_session_key(state.account_id || "default", inbound, scope)

  defp normalize_msg_id(msg_id), do: SessionRouting.normalize_msg_id(msg_id)

  defp maybe_mark_new_session_pending(state, inbound) do
    {chat_id, thread_id} = extract_chat_ids(inbound)
    SessionRouting.maybe_mark_new_session_pending(state.pending_new, chat_id, thread_id, inbound)
  end

  defp maybe_apply_selected_resume(state, inbound, original_text) do
    ResumeSelection.maybe_apply_selected_resume(
      state.account_id || "default",
      inbound,
      original_text
    )
  end

  # Mark an inbound as eligible for a new parallel session when the base session is busy.
  #
  # This is applied before buffering so we can avoid prefixing resume tokens to
  # auto-forked sessions.
  defp maybe_mark_fork_when_busy(state, inbound) do
    {chat_id, thread_id} = extract_chat_ids(inbound)

    SessionRouting.maybe_mark_fork_when_busy(
      state.account_id || "default",
      inbound,
      chat_id,
      thread_id
    )
  end

  defp resolve_session_key(state, inbound, %ChatScope{} = scope, meta0) do
    SessionRouting.resolve_session_key(
      state.account_id || "default",
      inbound,
      scope,
      meta0,
      current_thread_generation(state, scope.chat_id, scope.topic_id)
    )
  end

  defp resolve_session_key(_state, _inbound, _scope, meta0) do
    SessionRouting.resolve_session_key(nil, nil, nil, meta0, 0)
  end

  defp lookup_session_key_for_reply(state, %ChatScope{} = scope, reply_to_id)
       when is_integer(reply_to_id) do
    SessionRouting.lookup_session_key_for_reply(
      state.account_id || "default",
      scope,
      reply_to_id,
      current_thread_generation(state, scope.chat_id, scope.topic_id)
    )
  end

  defp lookup_session_key_for_reply(_state, _scope, _reply_to_id), do: nil

  defp maybe_index_telegram_msg_session(state, %ChatScope{} = scope, session_key, msg_ids),
    do:
      SessionRouting.maybe_index_telegram_msg_session(
        state.account_id || "default",
        scope,
        session_key,
        msg_ids,
        current_thread_generation(state, scope.chat_id, scope.topic_id)
      )

  defp send_system_message(state, chat_id, thread_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    delivery_opts =
      []
      |> maybe_put_kw(:account_id, state.account_id || "default")
      |> maybe_put_kw(:thread_id, thread_id)
      |> maybe_put_kw(:reply_to_message_id, reply_to_message_id)

    case Delivery.enqueue_send(chat_id, text, delivery_opts) do
      :ok ->
        :ok

      {:error, reason} when reason in [:channels_outbox_unavailable, :queue_full] ->
        opts =
          %{}
          |> maybe_put("reply_to_message_id", reply_to_message_id)
          |> maybe_put("message_thread_id", thread_id)

        state.api_mod.send_message(state.token, chat_id, text, opts, nil)

      {:error, _} = error ->
        Logger.warning("Telegram feedback was not confirmed by the outbox")
        error
    end
  end

  defp send_critical_feedback(state, chat_id, thread_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    opts =
      %{}
      |> maybe_put("reply_to_message_id", reply_to_message_id)
      |> maybe_put("message_thread_id", thread_id)

    state.api_mod.send_message(state.token, chat_id, text, opts, nil)
  end

  defp resolve_bot_identity(bot_id, bot_username, api_mod, token) do
    bot_id = parse_int(bot_id) || bot_id
    bot_username = normalize_bot_username(bot_username)
    api_mod = normalize_api_mod(api_mod)

    cond do
      is_integer(bot_id) and is_binary(bot_username) and bot_username != "" ->
        {bot_id, bot_username}

      Code.ensure_loaded?(api_mod) and function_exported?(api_mod, :get_me, 1) ->
        case api_mod.get_me(token) do
          {:ok, %{"ok" => true, "result" => %{"id" => id, "username" => username}}} ->
            resolved = {parse_int(id) || id, normalize_bot_username(username)}
            Logger.info("[Telegram] Bot identity resolved via getMe: #{inspect(resolved)}")
            resolved

          other ->
            Logger.warning(
              "[Telegram] getMe returned unexpected result, bot_id/bot_username will be nil: #{inspect(other)}"
            )

            {bot_id, bot_username}
        end

      true ->
        Logger.warning(
          "[Telegram] No getMe available and no config bot_id/bot_username; mention detection will be disabled (api_mod=#{inspect(api_mod)})"
        )

        {bot_id, bot_username}
    end
  rescue
    error ->
      Logger.error(
        "[Telegram] resolve_bot_identity crashed: #{inspect(error)}; mention detection will be disabled"
      )

      {bot_id, bot_username}
  end

  defp normalize_bot_username(nil), do: nil

  defp normalize_bot_username(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp should_ignore_for_trigger?(state, inbound, text) do
    ChatPreferences.should_ignore_for_trigger?(state, inbound, text, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      maybe_select_project_for_scope: &maybe_select_project_for_scope/2,
      send_system_message: &send_system_message/5
    })
  end

  defp handle_trigger_command(state, inbound) do
    ChatPreferences.handle_trigger_command(state, inbound, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      maybe_select_project_for_scope: &maybe_select_project_for_scope/2,
      send_system_message: &send_system_message/5
    })
  end

  defp handle_thinking_command(state, inbound) do
    ChatPreferences.handle_thinking_command(state, inbound, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      maybe_select_project_for_scope: &maybe_select_project_for_scope/2,
      send_system_message: &send_system_message/5
    })
  end

  defp handle_checkpoint_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      text = inbound.message.text || ""
      rollback? = Commands.rollback_command?(text, state.bot_username)

      args =
        Commands.telegram_command_args(text, if(rollback?, do: "rollback", else: "checkpoint"))

      agent_id = BindingResolver.resolve_agent_id(scope)

      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          checkpoint_message(args, rollback?,
            agent_id: agent_id,
            session_key: session_key,
            sender_id: inbound.sender && inbound.sender.id,
            checkpoint_owner:
              LemonChannels.CheckpointStatusMessage.owner_for_session_key(session_key)
          )
        )
    end

    state
  rescue
    _ -> state
  end

  defp checkpoint_message(args, true, opts),
    do: LemonChannels.CheckpointStatusMessage.handle_rollback(args, opts)

  defp checkpoint_message(args, false, opts),
    do: LemonChannels.CheckpointStatusMessage.handle(args, opts)

  defp handle_goal_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      args = Commands.telegram_command_args(inbound.message.text || "", "goal")
      agent_id = BindingResolver.resolve_agent_id(scope)

      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          LemonChannels.GoalStatusMessage.handle(session_key, args,
            agent_id: agent_id,
            workspace: BindingResolver.resolve_cwd(scope),
            # Goal work runs later under this chat's channel-run authority.
            channel_context: %{
              channel_id: inbound.channel_id,
              account_id: inbound.account_id,
              peer_kind: inbound.peer.kind,
              peer_id: inbound.peer.id,
              thread_id: inbound.peer.thread_id
            },
            meta: %{transport: "telegram"}
          )
        )
    end

    state
  rescue
    _ -> state
  end

  defp handle_kanban_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      args = Commands.telegram_command_args(inbound.message.text || "", "kanban")
      session_key = build_session_key(state, inbound, scope)

      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          LemonChannels.KanbanStatusMessage.handle(args,
            agent_id: BindingResolver.resolve_agent_id(scope),
            session_key: session_key,
            workspace: BindingResolver.resolve_cwd(scope),
            # Only the transport's per-human attestation authorizes changes; an
            # allowed group chat alone does not.
            operator?: get_in(inbound, [Access.key(:sender), :owner?]) == true,
            channel_context: %{
              channel_id: inbound.channel_id,
              account_id: inbound.account_id,
              peer_kind: inbound.peer.kind,
              peer_id: inbound.peer.id,
              thread_id: inbound.peer.thread_id
            },
            meta: %{"notificationSessionKey" => session_key, transport: "telegram"}
          )
        )
    end

    state
  end

  defp handle_remind_command(state, inbound) do
    handle_reminder_command(state, inbound, "remind", fn args, opts ->
      LemonChannels.Reminders.create(args, opts)
    end)
  end

  defp handle_reminders_command(state, inbound) do
    handle_reminder_command(state, inbound, "reminders", fn _args, opts ->
      LemonChannels.Reminders.list(opts)
    end)
  end

  defp handle_unremind_command(state, inbound) do
    handle_reminder_command(state, inbound, "unremind", fn args, opts ->
      LemonChannels.Reminders.cancel(args, opts)
    end)
  end

  defp handle_reminder_command(state, inbound, command, reply_fun) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      args = Commands.telegram_command_args(inbound.message.text || "", command)
      agent_id = BindingResolver.resolve_agent_id(scope)

      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          reply_fun.(args,
            session_key: session_key,
            agent_id: agent_id,
            created_via: "telegram"
          )
        )
    end

    state
  end

  defp handle_media_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      args = Commands.telegram_command_args(inbound.message.text || "", "media")

      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          LemonChannels.MediaStatusMessage.handle(args)
        )
    end

    state
  end

  defp handle_portable_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if is_integer(chat_id) do
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      {command, args} = Commands.portable_command_parts(inbound.message.text || "")

      context = %{
        surface: "telegram",
        account_id: state.account_id,
        approval_authorize:
          ApprovalRequest.text_authorizer(state, %{
            "message_id" => user_msg_id,
            "message_thread_id" => thread_id,
            "chat" => %{
              "id" => chat_id,
              "type" => to_string(inbound.meta[:chat_type])
            }
          }),
        session_key: session_key,
        cwd: BindingResolver.resolve_cwd(scope),
        model: inbound.meta[:model],
        thinking_level: inbound.meta[:thinking_level]
      }

      run = fn ->
        text =
          case LemonChannels.PortableCommand.handle(command, args, context) do
            {:ok, result} -> result
            {:error, message} -> message
          end

        send_system_message(state, chat_id, thread_id, user_msg_id, text)
      end

      if command == "btw" do
        case start_async_task(state, fn ->
               send_system_message(
                 state,
                 chat_id,
                 thread_id,
                 user_msg_id,
                 "Answering side question…"
               )

               run.()
             end) do
          {:ok, _pid} ->
            :ok

          {:error, _reason} ->
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Side question could not be started."
            )
        end
      else
        _ = run.()
      end
    end

    state
  end

  defp handle_cwd_command(state, inbound) do
    ChatPreferences.handle_cwd_command(state, inbound, %{
      extract_chat_ids: &extract_chat_ids/1,
      extract_message_ids: &extract_message_ids/1,
      maybe_select_project_for_scope: &maybe_select_project_for_scope/2,
      send_system_message: &send_system_message/5
    })
  end

  defp persist_offset(state, new_offset) do
    if new_offset != state.offset do
      OffsetStore.put(state.account_id, state.token, new_offset)
    end

    :ok
  end

  defp maybe_log_drop(state, inbound, reason) do
    UpdateProcessor.log_drop(state, inbound, reason)
  end

  defp merge_config(base, nil), do: base

  defp merge_config(base, cfg) when is_map(cfg) do
    Map.merge(base || %{}, cfg)
  end

  defp merge_config(base, cfg) when is_list(cfg) do
    if Keyword.keyword?(cfg) do
      Map.merge(base || %{}, Enum.into(cfg, %{}))
    else
      base || %{}
    end
  end

  defp maybe_subscribe_exec_approvals do
    case LemonCore.Bus.subscribe("exec_approvals") do
      :ok -> :ok
      other -> Logger.warning("Telegram exec approvals subscription returned #{inspect(other)}")
    end

    :ok
  rescue
    error ->
      Logger.warning("Telegram exec approvals subscription failed: #{Exception.message(error)}")
      :ok
  end

  defp send_approval_request(state, payload) when is_map(state) and is_map(payload) do
    ApprovalRequest.send(state, payload)
  end

  defp send_approval_request(_state, _payload), do: :ok

  defp handle_callback_query(state, cb) when is_map(state) and is_map(cb) do
    CallbackHandler.handle_callback_query(state, cb)
  end

  defp handle_callback_query(_state, _cb), do: :ok

  defp handle_topic_command(state, inbound) do
    TopicCommand.handle_topic_command(state, inbound, %{
      extract_message_ids: &extract_message_ids/1,
      send_system_message: &send_system_message/5
    })
  end

  defp maybe_transcribe_voice(state, inbound) do
    VoiceHandler.maybe_transcribe_voice(
      state,
      inbound,
      &send_system_message/5,
      &extract_message_ids/1
    )
  end

  defp resolve_openai_provider do
    cfg = LemonCore.Config.load()
    providers = cfg.providers || %{}
    provider = Map.get(providers, "openai") || Map.get(providers, :openai) || %{}

    {map_get(provider, :api_key), map_get(provider, :base_url)}
  end

  defp normalize_blank(nil), do: nil
  defp normalize_blank(""), do: nil
  defp normalize_blank(value), do: value

  defp cfg_get(cfg, key, default \\ nil) when is_atom(key) do
    cfg[key] || cfg[Atom.to_string(key)] || default
  end

  defp resolve_api_mod(config) do
    config
    |> cfg_get(:api_mod, LemonChannels.Telegram.API)
    |> normalize_api_mod()
  end

  defp normalize_api_mod(mod) when is_atom(mod), do: mod

  defp normalize_api_mod(""), do: LemonChannels.Telegram.API

  defp normalize_api_mod(mod) when is_binary(mod) do
    module =
      if String.starts_with?(mod, "Elixir.") do
        String.to_existing_atom(mod)
      else
        String.to_existing_atom("Elixir." <> mod)
      end

    module
  rescue
    ArgumentError ->
      Logger.warning(
        "telegram api_mod #{inspect(mod)} does not resolve to a loaded module; " <>
          "falling back to the real Telegram API"
      )

      LemonChannels.Telegram.API
  end

  defp normalize_api_mod(_), do: LemonChannels.Telegram.API

  defp extract_message_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)
    {chat_id, thread_id, user_msg_id}
  end

  defp extract_chat_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    {chat_id, thread_id}
  end

  defp parse_int(nil), do: nil

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp maybe_put_kw(opts, _key, nil) when is_list(opts), do: opts
  defp maybe_put_kw(opts, key, value) when is_list(opts), do: [{key, value} | opts]

  defp start_async_task(_state, fun) when is_function(fun, 0) do
    case LemonCore.TaskSupervisor.start_child(async_supervisor_name(), fun) do
      {:ok, _pid} = result ->
        result

      {:error, :task_supervisor_unavailable} ->
        Logger.warning("telegram background task supervisor unavailable")
        {:error, :async_supervisor_unavailable}

      {:error, _reason} = error ->
        Logger.warning("telegram background task admission failed")
        error
    end
  end

  defp start_async_task(_state, _fun), do: :ok

  defp async_supervisor_name, do: LemonChannels.Adapters.Telegram.AsyncSupervisor

  defp map_get(map, key), do: MapHelpers.get_key(map, key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

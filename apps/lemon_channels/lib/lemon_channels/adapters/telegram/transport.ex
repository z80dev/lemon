defmodule LemonChannels.Adapters.Telegram.Transport do
  @moduledoc """
  Telegram polling transport shell.

  The transport owns lifecycle, polling, timer receipt, and adapter-local
  runtime state, while normalized ingress flows through Telegram-local
  normalize/pipeline/action-runner helpers before router submission.
  """

  use GenServer

  require Logger

  alias LemonChannels.BindingResolver
  alias LemonChannels.Cwd
  alias LemonChannels.Telegram.{OffsetStore, PollerLock}
  alias LemonChannels.Telegram.Delivery
  alias LemonChannels.Telegram.TriggerMode
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope
  alias LemonCore.ProjectBindingStore
  alias LemonCore.MapHelpers
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.Adapters.Telegram.Transport.ActionRunner
  alias LemonChannels.Adapters.Telegram.Transport.CallbackHandler
  alias LemonChannels.Adapters.Telegram.Transport.CommandRouter
  alias LemonChannels.Adapters.Telegram.Transport.ModelPicker
  alias LemonChannels.Adapters.Telegram.Transport.FileOperations
  alias LemonChannels.Adapters.Telegram.Transport.InboundActions
  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonChannels.Adapters.Telegram.Transport.MessageBuffer
  alias LemonChannels.Adapters.Telegram.Transport.Normalize
  alias LemonChannels.Adapters.Telegram.Transport.Pipeline
  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.Poller
  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.Adapters.Telegram.Transport.RuntimeState
  alias LemonChannels.Adapters.Telegram.Transport.VoiceHandler
  alias LemonChannels.Adapters.Telegram.Transport.SessionRouting
  alias LemonChannels.Adapters.Telegram.Transport.UpdateProcessor
  alias LemonCore.Config

  @default_poll_interval 1_000
  @default_dedupe_ttl 600_000
  @default_debounce_ms 1_000
  @model_default_engine "lemon"
  @thinking_levels ~w(off minimal low medium high xhigh)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
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
          :ok = TransportShared.init_dedupe(:channels)

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
              deny_unbound_chats: cfg_get(config, :deny_unbound_chats, false),
              account_id: account_id,
              voice_transcription: cfg_get(config, :voice_transcription, false),
              voice_transcription_model:
                cfg_get(config, :voice_transcription_model, "gpt-4o-mini-transcribe"),
              voice_transcription_base_url:
                normalize_blank(cfg_get(config, :voice_transcription_base_url)) || openai_base_url,
              voice_transcription_api_key:
                normalize_blank(cfg_get(config, :voice_transcription_api_key)) || openai_api_key,
              voice_max_bytes: cfg_get(config, :voice_max_bytes, 10 * 1024 * 1024),
              voice_transcriber:
                config[:voice_transcriber] || LemonChannels.Adapters.Telegram.VoiceTranscriber,
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

          maybe_subscribe_exec_approvals()
          send(self(), :poll)
          {:ok, state}

        {:error, :locked} ->
          Logger.warning(
            "Telegram poller already running for account_id=#{inspect(account_id)}; refusing to start lemon_channels transport"
          )

          :ignore
      end
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = poll_updates(state)
    Process.send_after(self(), :poll, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:debounce_flush, scope_key, debounce_ref}, state) do
    {:noreply, dispatch_transport_event({:debounce_flush, scope_key, debounce_ref}, state)}
  end

  def handle_info({:media_group_flush, group_key, debounce_ref}, state) do
    {:noreply, dispatch_transport_event({:media_group_flush, group_key, debounce_ref}, state)}
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    {:noreply, dispatch_transport_event({:approval_requested, payload}, state)}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  # Best-effort second pass to clear chat state in case a late write races with the first delete.
  def handle_info(
        {:new_session_cleanup, session_key, chat_id, thread_id},
        state
      ) do
    _ = safe_delete_chat_state(session_key)
    _ = safe_delete_selected_resume(state, chat_id, thread_id)
    _ = safe_sweep_thread_message_indices(state, chat_id, thread_id, :all)
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  # /new triggers an internal "memory reflection" run; only clear auto-resume after it completes.
  def handle_info(%LemonCore.Event{type: :run_completed, meta: meta} = event, state) do
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
            self(),
            {:new_session_cleanup, sk, chat_id, thread_id},
            50
          )

          topic = LemonCore.Bus.run_topic(run_id)
          _ = LemonCore.Bus.unsubscribe(topic)

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
          if Code.ensure_loaded?(LemonCore.Bus) and
               function_exported?(LemonCore.Bus, :unsubscribe, 1) do
            topic = LemonCore.Bus.session_topic(session_key)
            _ = LemonCore.Bus.unsubscribe(topic)
          end

          %{state | reaction_runs: Map.delete(state.reaction_runs, session_key)}

        _ ->
          state
      end

    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = PollerLock.release(state.account_id, state.token)
    :ok
  end

  defp poll_updates(state) do
    Poller.poll_updates(state, %{
      handle_callback_query: &handle_callback_query/2,
      execute_inbound_message: &execute_inbound_message/2,
      index_known_target: &index_known_target/2,
      maybe_log_drop: &maybe_log_drop/3,
      maybe_transcribe_voice: &maybe_transcribe_voice/2,
      process_media_group: &process_media_group/2,
      persist_offset: &persist_offset/2,
      send_approval_request: &send_approval_request/2,
      start_async_task: &start_async_task/2,
      submit_buffer: &submit_buffer/2
    })
  end

  defp dispatch_transport_event(event, state) do
    with {:ok, normalized} <- Normalize.event(state, event),
         {state, actions} <- Pipeline.run(normalized, state) do
      ActionRunner.run(state, actions, pipeline_callbacks())
    else
      {:error, _reason} -> state
      {:skip, new_state} -> new_state
    end
  rescue
    _ -> state
  end

  defp pipeline_callbacks do
    %{
      handle_callback_query: &handle_callback_query/2,
      execute_inbound_message: &execute_inbound_message/2,
      index_known_target: &index_known_target/2,
      maybe_log_drop: &maybe_log_drop/3,
      process_media_group: &process_media_group/2,
      send_approval_request: &send_approval_request/2,
      start_async_task: &start_async_task/2,
      submit_buffer: &submit_buffer/2
    }
  end

  defp execute_inbound_message(state, inbound) do
    CommandRouter.handle_inbound_message(state, inbound, %{
      bot_username: state.bot_username,
      handle_cwd_command: &handle_cwd_command/2,
      handle_media_auto_put: &handle_media_auto_put/2,
      handle_model_command: &ModelPicker.handle_model_command/2,
      handle_new_session: &handle_new_session/3,
      handle_reload_command: &handle_reload_command/2,
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
      submit_inbound_now: &submit_inbound_now/2
    })
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
      update_chat_state_last_engine: &update_chat_state_last_engine/2
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

    if is_integer(chat_id) and reply_to_id do
      case Integer.parse(to_string(reply_to_id)) do
        {progress_msg_id, _} ->
          scope = %LemonCore.ChatScope{
            transport: :telegram,
            chat_id: chat_id,
            topic_id: thread_id
          }

          session_key =
            lookup_session_key_for_reply(state, scope, progress_msg_id) ||
              build_session_key(state, inbound, scope)

          if Code.ensure_loaded?(LemonChannels.Runtime) and
               function_exported?(LemonChannels.Runtime, :cancel_by_progress_msg, 2) do
            LemonChannels.Runtime.cancel_by_progress_msg(session_key, progress_msg_id)
          end

          :ok

        _ ->
          :ok
      end
    end

    state
  rescue
    _ -> state
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
  rescue
    _ -> :ok
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
  rescue
    _ -> state
  end

  defp maybe_select_project_for_scope(%ChatScope{} = scope, selector) when is_binary(selector) do
    sel = String.trim(selector || "")

    cond do
      sel == "" ->
        :noop

      looks_like_path?(sel) ->
        base =
          case BindingResolver.resolve_cwd(scope) do
            cwd when is_binary(cwd) and byte_size(cwd) > 0 -> cwd
            _ -> Cwd.default_cwd()
          end

        expanded =
          case Path.type(sel) do
            :absolute -> Path.expand(sel)
            :relative -> Path.expand(sel, base)
            _ -> Path.expand(sel, base)
          end

        if File.dir?(expanded) do
          id = Path.basename(expanded)
          root = expanded

          ProjectBindingStore.put_dynamic(id, %{root: root, default_engine: nil})
          ProjectBindingStore.put_override(scope, id)

          {:ok, %{id: id, root: root}}
        else
          {:error, "Project path does not exist: #{expanded}"}
        end

      true ->
        id = sel

        case BindingResolver.lookup_project(id) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 ->
            root = Path.expand(root)

            if File.dir?(root) do
              ProjectBindingStore.put_override(scope, id)

              {:ok, %{id: id, root: root}}
            else
              {:error, "Configured project root does not exist: #{root}"}
            end

          _ ->
            {:error, "Unknown project: #{id}"}
        end
    end
  rescue
    _ -> {:error, "Failed to select project."}
  end

  defp looks_like_path?(s) when is_binary(s) do
    String.starts_with?(s, "/") or String.starts_with?(s, "~") or String.starts_with?(s, ".") or
      String.contains?(s, "/")
  end

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

    state = MessageBuffer.drop_buffer_for(state, inbound)

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      session_key = build_session_key(state, inbound, scope)
      selector = normalize_selector(raw_selector)

      project_result =
        case selector do
          nil -> :noop
          sel -> maybe_select_project_for_scope(scope, sel)
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
  rescue
    _ -> state
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
    project = extract_project_info(project_result)

    {previous_generation, _new_generation} = bump_thread_generation(state, chat_id, thread_id)

    # Clear selected resume immediately so the next inbound after /new cannot
    # inherit stale auto-resume state while cleanup runs in the background.
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
  end

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
    _ = safe_abort_session(session_key, :new_session)
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

    # Store writes are async in some flows; repeat the cleanup once to win races.
    Process.sleep(50)
    _ = safe_delete_chat_state(session_key)
    _ = safe_delete_selected_resume(state, chat_id, thread_id)
    _ = safe_sweep_thread_message_indices(state, chat_id, thread_id, previous_generation)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_subscribe_to_session(session_key) when is_binary(session_key) do
    if Code.ensure_loaded?(LemonCore.Bus) and
         function_exported?(LemonCore.Bus, :subscribe, 1) do
      topic = LemonCore.Bus.session_topic(session_key)
      _ = LemonCore.Bus.subscribe(topic)
    end
  end

  defp maybe_subscribe_to_run(run_id) do
    if Code.ensure_loaded?(LemonCore.Bus) and
         function_exported?(LemonCore.Bus, :subscribe, 1) do
      topic = LemonCore.Bus.run_topic(run_id)
      _ = LemonCore.Bus.subscribe(topic)
    end
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

    engine_line = resolve_new_session_engine(session_key, model_hint)
    cwd_line = resolve_new_session_cwd(scope)
    account_line = state.account_id || "default"

    session_line =
      if(is_binary(session_key) and session_key != "", do: session_key, else: "(unavailable)")

    [
      base_msg,
      "Model: #{model_line}",
      "Thinking: #{thinking_line}",
      "Provider: #{provider_line}",
      "Engine: #{engine_line}",
      "CWD: #{cwd_line}",
      "Account: #{account_line}",
      "Session key: #{session_line}"
    ]
    |> maybe_append_project_line(project)
    |> Enum.join("\n")
  rescue
    _ -> base_msg
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

  defp resolve_new_session_engine(session_key, model_hint) do
    cond do
      is_binary(model_hint) and model_hint != "" ->
        "#{@model_default_engine} (from model selection)"

      true ->
        case last_engine_hint(session_key) do
          engine when is_binary(engine) and engine != "" ->
            engine

          _ ->
            cfg = Config.cached()
            gw = map_get(cfg, :gateway) || %{}
            default_eng = map_get(gw, :default_engine) || "lemon"
            "#{default_eng} (default)"
        end
    end
  rescue
    _ ->
      cfg = Config.cached()
      gw = map_get(cfg, :gateway) || %{}
      default_eng = map_get(gw, :default_engine) || "lemon"
      "#{default_eng} (default)"
  end

  defp resolve_new_session_cwd(%ChatScope{} = scope) do
    case BindingResolver.resolve_cwd(scope) do
      cwd when is_binary(cwd) and cwd != "" ->
        Path.expand(cwd)

      _ ->
        case Cwd.default_cwd() do
          cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
          _ -> "(not configured)"
        end
    end
  rescue
    _ -> "(not configured)"
  end

  defp resolve_new_session_cwd(_), do: "(not configured)"

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
  rescue
    _ -> :skip
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

  defp last_engine_hint(session_key), do: PerChatState.last_engine_hint(session_key)

  defp safe_delete_chat_state(key), do: PerChatState.safe_delete_chat_state(key)

  defp safe_delete_session_model(session_key),
    do: PerChatState.safe_delete_session_model(session_key)

  defp safe_abort_session(session_key, reason),
    do: PerChatState.safe_abort_session(session_key, reason)

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

  defp default_thinking_preference(account_id, chat_id, thread_id),
    do: ModelPolicyAdapter.default_thinking_preference(account_id, chat_id, thread_id)

  defp put_default_thinking_preference(account_id, chat_id, thread_id, level),
    do: ModelPolicyAdapter.put_default_thinking_preference(account_id, chat_id, thread_id, level)

  defp clear_default_thinking_preference(account_id, chat_id, thread_id),
    do: ModelPolicyAdapter.clear_default_thinking_preference(account_id, chat_id, thread_id)

  # Update only last_engine in chat state, preserving last_resume_token and other fields.
  defp update_chat_state_last_engine(session_key, engine),
    do: PerChatState.update_chat_state_last_engine(session_key, engine)

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

      {:error, _reason} ->
        opts =
          %{}
          |> maybe_put("reply_to_message_id", reply_to_message_id)
          |> maybe_put("message_thread_id", thread_id)

        _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
        :ok
    end
  rescue
    _ -> :ok
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
    case inbound.peer.kind do
      :group ->
        trigger_mode = trigger_mode_for(state, inbound)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      :channel ->
        trigger_mode = trigger_mode_for(state, inbound)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp trigger_mode_for(state, inbound) do
    {chat_id, topic_id} = extract_chat_ids(inbound)
    account_id = state.account_id || "default"

    if is_integer(chat_id) do
      TriggerMode.resolve(account_id, chat_id, topic_id)
    else
      %{mode: :all, chat_mode: nil, topic_mode: nil, source: :default}
    end
  rescue
    _ -> %{mode: :all, chat_mode: nil, topic_mode: nil, source: :default}
  end

  defp explicit_invocation?(state, inbound, text) do
    Commands.command_message_for_bot?(text, state.bot_username) or
      mention_of_bot?(state, inbound) or
      reply_to_bot?(state, inbound)
  rescue
    _ -> false
  end

  defp mention_of_bot?(state, inbound) do
    bot_username = state.bot_username
    bot_id = state.bot_id
    message = inbound_message_from_update(inbound.raw)
    text = message["text"] || message["caption"] || inbound.message.text || ""

    mention_by_username =
      if is_binary(bot_username) and bot_username != "" do
        Regex.match?(~r/(?:^|\W)@#{Regex.escape(bot_username)}(?:\b|$)/i, text || "")
      else
        false
      end

    mention_by_id =
      if is_integer(bot_id) do
        entities = message_entities(message)

        Enum.any?(entities, fn entity ->
          case entity do
            %{"type" => "text_mention", "user" => %{"id" => id}} ->
              parse_int(id) == bot_id

            _ ->
              false
          end
        end)
      else
        false
      end

    mention_by_username or mention_by_id
  rescue
    _ -> false
  end

  defp reply_to_bot?(state, inbound) do
    message = inbound_message_from_update(inbound.raw)
    reply = message["reply_to_message"] || %{}
    thread_id = message["message_thread_id"]

    cond do
      reply == %{} ->
        false

      topic_root_reply?(thread_id, reply) ->
        false

      is_integer(state.bot_id) and get_in(reply, ["from", "id"]) == state.bot_id ->
        true

      is_binary(state.bot_username) and state.bot_username != "" ->
        reply_username = get_in(reply, ["from", "username"])

        is_binary(reply_username) and
          String.downcase(reply_username) == String.downcase(state.bot_username)

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp topic_root_reply?(thread_id, reply) do
    is_integer(thread_id) and is_map(reply) and reply["message_id"] == thread_id
  end

  defp inbound_message_from_update(update) when is_map(update) do
    cond do
      is_map(update["message"]) -> update["message"]
      is_map(update["edited_message"]) -> update["edited_message"]
      is_map(update["channel_post"]) -> update["channel_post"]
      true -> %{}
    end
  end

  defp inbound_message_from_update(_), do: %{}

  defp message_entities(message) when is_map(message) do
    entities = message["entities"] || message["caption_entities"]
    if is_list(entities), do: entities, else: []
  end

  defp message_entities(_), do: []

  defp handle_trigger_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    args = Commands.telegram_command_args(inbound.message.text, "trigger") || ""
    arg = String.downcase(String.trim(args || ""))
    account_id = state.account_id || "default"

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      ctx = {state, chat_id, thread_id, user_msg_id, account_id, scope, inbound}

      case arg do
        "" ->
          current = TriggerMode.resolve(account_id, chat_id, thread_id)

          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_trigger_mode_status(current)
            )

          state

        mode when mode in ~w(mentions all) ->
          apply_trigger_mode(ctx, String.to_existing_atom(mode), mode)

        "clear" ->
          apply_trigger_clear(ctx)

        _ ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Usage: /trigger [mentions|all|clear]"
            )

          state
      end
    end
  rescue
    _ -> state
  end

  defp apply_trigger_mode(
         {state, chat_id, thread_id, user_msg_id, account_id, scope, inbound},
         mode_atom,
         mode_str
       ) do
    with true <- trigger_change_allowed?(state, inbound, chat_id),
         :ok <- TriggerMode.set(scope, account_id, mode_atom) do
      _ =
        send_system_message(
          state,
          chat_id,
          thread_id,
          user_msg_id,
          render_trigger_mode_set(mode_str, scope)
        )

      state
    else
      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Trigger mode can only be changed by a group admin."
          )

        state

      _ ->
        state
    end
  end

  defp apply_trigger_clear({state, chat_id, thread_id, user_msg_id, account_id, _scope, inbound}) do
    cond do
      is_nil(thread_id) ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "No topic override to clear. Use /trigger all or /trigger mentions to set chat defaults."
          )

        state

      trigger_change_allowed?(state, inbound, chat_id) ->
        :ok = TriggerMode.clear_topic(account_id, chat_id, thread_id)

        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Cleared topic trigger override."
          )

        state

      true ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Trigger mode can only be changed by a group admin."
          )

        state
    end
  end

  defp trigger_change_allowed?(state, inbound, chat_id) do
    case inbound.peer.kind do
      :group ->
        sender_id = parse_int(inbound.sender && inbound.sender.id)

        if is_integer(sender_id) do
          sender_admin?(state, chat_id, sender_id)
        else
          false
        end

      _ ->
        true
    end
  end

  defp sender_admin?(state, chat_id, sender_id) do
    if function_exported?(state.api_mod, :get_chat_member, 3) do
      case state.api_mod.get_chat_member(state.token, chat_id, sender_id) do
        {:ok, %{"ok" => true, "result" => %{"status" => status}}}
        when status in ["administrator", "creator"] ->
          true

        _ ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp render_trigger_mode_status(%{mode: mode, chat_mode: chat_mode, topic_mode: topic_mode}) do
    base =
      case mode do
        :mentions -> "Trigger mode: mentions-only."
        _ -> "Trigger mode: all."
      end

    chat_line =
      case chat_mode do
        :mentions -> "Chat default: mentions-only."
        :all -> "Chat default: all."
        _ -> "Chat default: all."
      end

    topic_line =
      case topic_mode do
        :mentions -> "Topic override: mentions-only."
        :all -> "Topic override: all."
        _ -> "Topic override: none."
      end

    [base, chat_line, topic_line, "Use /trigger mentions|all|clear."]
    |> Enum.join("\n")
  end

  defp render_trigger_mode_set(mode, %ChatScope{topic_id: nil}) do
    "Trigger mode set to #{mode} for this chat."
  end

  defp render_trigger_mode_set(mode, %ChatScope{topic_id: _}) do
    "Trigger mode set to #{mode} for this topic."
  end

  defp handle_thinking_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    args = String.trim(Commands.telegram_command_args(inbound.message.text, "thinking") || "")

    if not is_integer(chat_id) do
      state
    else
      account_id = state.account_id || "default"
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

      case normalize_thinking_command_arg(args) do
        :status ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_thinking_status(state, scope)
            )

          state

        :clear ->
          had_override? = clear_default_thinking_preference(account_id, chat_id, thread_id)

          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_thinking_cleared(scope, had_override?)
            )

          state

        {:set, level} ->
          :ok = put_default_thinking_preference(account_id, chat_id, thread_id, level)

          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_thinking_set(scope, level)
            )

          state

        :invalid ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, thinking_usage())
          state
      end
    end
  rescue
    _ -> state
  end

  defp handle_reload_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    if not is_integer(chat_id) do
      state
    else
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Recompiling...")

      case IEx.Helpers.recompile() do
        :ok ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Recompile complete."
            )

        :noop ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Nothing to recompile — code is up to date."
            )

        {:error, _} ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "Recompile failed — check the build output on the server."
            )
      end

      state
    end
  rescue
    _ -> state
  end

  defp normalize_thinking_command_arg(args) when is_binary(args) do
    case String.downcase(String.trim(args)) do
      "" -> :status
      "clear" -> :clear
      level when level in @thinking_levels -> {:set, level}
      _ -> :invalid
    end
  end

  defp normalize_thinking_command_arg(_), do: :invalid

  defp render_thinking_status(state, %ChatScope{} = scope) do
    account_id = state.account_id || "default"
    chat_id = scope.chat_id
    topic_id = scope.topic_id

    topic_level =
      if is_integer(topic_id),
        do: default_thinking_preference(account_id, chat_id, topic_id),
        else: nil

    chat_level = default_thinking_preference(account_id, chat_id, nil)

    {effective_level, source} =
      cond do
        is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
        is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
        true -> {nil, nil}
      end

    scope_label = thinking_scope_label(scope)

    effective_line =
      "Thinking level for #{scope_label}: #{format_thinking_line(effective_level, source)}"

    chat_line =
      case chat_level do
        level when is_binary(level) and level != "" -> "Chat default: #{level}."
        _ -> "Chat default: none."
      end

    topic_line =
      case topic_level do
        level when is_binary(level) and level != "" -> "Topic override: #{level}."
        _ -> "Topic override: none."
      end

    [effective_line, chat_line, topic_line, thinking_usage()]
    |> Enum.join("\n")
  rescue
    _ -> thinking_usage()
  end

  defp render_thinking_set(%ChatScope{topic_id: topic_id}, level)
       when is_integer(topic_id) and is_binary(level) do
    [
      "Thinking level set to #{level} for this topic.",
      "New runs in this topic will use this setting.",
      thinking_usage()
    ]
    |> Enum.join("\n")
  end

  defp render_thinking_set(%ChatScope{}, level) when is_binary(level) do
    [
      "Thinking level set to #{level} for this chat.",
      "New runs in this chat will use this setting.",
      thinking_usage()
    ]
    |> Enum.join("\n")
  end

  defp render_thinking_set(_scope, level) when is_binary(level),
    do: "Thinking level set to #{level}."

  defp render_thinking_cleared(%ChatScope{topic_id: topic_id}, had_override?)
       when is_integer(topic_id) do
    if had_override? do
      "Cleared thinking level override for this topic."
    else
      "No /thinking override was set for this topic."
    end
  end

  defp render_thinking_cleared(%ChatScope{}, had_override?) do
    if had_override? do
      "Cleared thinking level override for this chat."
    else
      "No /thinking override was set for this chat."
    end
  end

  defp render_thinking_cleared(_scope, _had_override?), do: "Thinking level override cleared."

  defp thinking_scope_label(%ChatScope{topic_id: topic_id}) when is_integer(topic_id),
    do: "this topic"

  defp thinking_scope_label(_), do: "this chat"

  defp thinking_usage, do: "Usage: /thinking [off|minimal|low|medium|high|xhigh|clear]"

  defp handle_cwd_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    args = String.trim(Commands.telegram_command_args(inbound.message.text, "cwd") || "")

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

      case String.downcase(args) do
        "" ->
          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_cwd_status(scope)
            )

          state

        "clear" ->
          had_override? = scope_has_cwd_override?(scope)
          clear_cwd_override(scope)

          _ =
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_cwd_cleared(scope, had_override?)
            )

          state

        _ ->
          case maybe_select_project_for_scope(scope, args) do
            {:ok, %{root: root}} when is_binary(root) and root != "" ->
              _ =
                send_system_message(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  render_cwd_set(scope, root)
                )

              state

            {:error, msg} when is_binary(msg) ->
              _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
              state

            _ ->
              _ = send_system_message(state, chat_id, thread_id, user_msg_id, cwd_usage())
              state
          end
      end
    end
  rescue
    _ -> state
  end

  defp render_cwd_status(%ChatScope{} = scope) do
    cwd = BindingResolver.resolve_cwd(scope)
    scope_label = cwd_scope_label(scope)
    override? = scope_has_cwd_override?(scope)

    cond do
      is_binary(cwd) and cwd != "" and override? ->
        [
          "Working directory for #{scope_label}: #{cwd}",
          "Source: /cwd override.",
          "New sessions started with /new in #{scope_label} will use this directory.",
          cwd_usage()
        ]
        |> Enum.join("\n")

      is_binary(cwd) and cwd != "" ->
        [
          "Working directory for #{scope_label}: #{cwd}",
          "Source: binding/project configuration.",
          cwd_usage()
        ]
        |> Enum.join("\n")

      true ->
        [
          "No working directory configured for #{scope_label}.",
          "Set one with /cwd <project_id|path>.",
          cwd_usage()
        ]
        |> Enum.join("\n")
    end
  rescue
    _ -> cwd_usage()
  end

  defp render_cwd_set(scope, root) do
    scope_label = cwd_scope_label(scope)
    root = Path.expand(root)

    [
      "Working directory set for #{scope_label}: #{root}",
      "New sessions started with /new in #{scope_label} will use this directory.",
      cwd_usage()
    ]
    |> Enum.join("\n")
  end

  defp render_cwd_cleared(scope, had_override?) do
    scope_label = cwd_scope_label(scope)

    if had_override? do
      "Cleared working directory override for #{scope_label}."
    else
      "No /cwd override was set for #{scope_label}."
    end
  end

  defp cwd_scope_label(%ChatScope{topic_id: topic_id}) when is_integer(topic_id), do: "this topic"
  defp cwd_scope_label(_), do: "this chat"

  defp scope_has_cwd_override?(%ChatScope{} = scope) do
    case BindingResolver.get_project_override(scope) do
      override when is_binary(override) and override != "" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp scope_has_cwd_override?(_), do: false

  defp clear_cwd_override(%ChatScope{} = scope) do
    _ = ProjectBindingStore.delete_override(scope)
    :ok
  rescue
    _ -> :ok
  end

  defp clear_cwd_override(_), do: :ok

  defp cwd_usage, do: "Usage: /cwd [project_id|path|clear]"

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
    if Code.ensure_loaded?(LemonCore.Bus) and function_exported?(LemonCore.Bus, :subscribe, 1) do
      _ = LemonCore.Bus.subscribe("exec_approvals")
    end

    :ok
  rescue
    _ -> :ok
  end

  defp send_approval_request(state, payload) when is_map(state) and is_map(payload) do
    LemonChannels.Adapters.Telegram.Transport.ApprovalRequest.send(state, payload)
  end

  defp send_approval_request(_state, _payload), do: :ok

  defp handle_callback_query(state, cb) when is_map(state) and is_map(cb) do
    CallbackHandler.handle_callback_query(state, cb)
  end

  defp handle_callback_query(_state, _cb), do: :ok

  defp handle_topic_command(state, inbound) do
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    topic_name = String.trim(Commands.telegram_command_args(inbound.message.text, "topic") || "")

    cond do
      not is_integer(chat_id) ->
        state

      topic_name == "" ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, topic_usage())
        state

      not function_exported?(state.api_mod, :create_forum_topic, 3) ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "This Telegram API module does not support /topic."
          )

        state

      true ->
        case state.api_mod.create_forum_topic(state.token, chat_id, topic_name) do
          {:ok, %{"ok" => true, "result" => result}} ->
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_created_message(topic_name, result)
              )

            state

          {:ok, %{"result" => result}} ->
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_created_message(topic_name, result)
              )

            state

          {:ok, %{"description" => description}}
          when is_binary(description) and description != "" ->
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Failed to create topic: #{description}"
              )

            state

          {:error, reason} ->
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                topic_error_message(reason)
              )

            state

          _ ->
            _ =
              send_system_message(
                state,
                chat_id,
                thread_id,
                user_msg_id,
                "Failed to create topic."
              )

            state
        end
    end
  rescue
    _ -> state
  end

  defp topic_usage, do: "Usage: /topic <name>"

  defp topic_created_message(topic_name, result) when is_binary(topic_name) and is_map(result) do
    topic_id = parse_int(result["message_thread_id"] || result[:message_thread_id])

    if is_integer(topic_id) do
      "Created topic \"#{topic_name}\" (id: #{topic_id})."
    else
      "Created topic \"#{topic_name}\"."
    end
  rescue
    _ -> "Created topic \"#{topic_name}\"."
  end

  defp topic_created_message(topic_name, _result) do
    "Created topic \"#{topic_name}\"."
  end

  defp topic_error_message(reason) do
    case extract_topic_error_description(reason) do
      desc when is_binary(desc) and desc != "" -> "Failed to create topic: #{desc}"
      _ -> "Failed to create topic."
    end
  end

  defp extract_topic_error_description(%{"description" => desc})
       when is_binary(desc) and desc != "" do
    desc
  end

  defp extract_topic_error_description({:http_error, _status, body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} when is_binary(desc) and desc != "" -> desc
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extract_topic_error_description(_), do: nil

  defp maybe_transcribe_voice(state, inbound) do
    VoiceHandler.maybe_transcribe_voice(
      state,
      inbound,
      &send_system_message/5,
      &extract_message_ids/1
    )
  end

  defp resolve_openai_provider do
    provider =
      try do
        cfg = LemonCore.Config.load()
        providers = cfg.providers || %{}
        Map.get(providers, "openai") || Map.get(providers, :openai) || %{}
      rescue
        _ -> %{}
      end

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
    try do
      module =
        if String.starts_with?(mod, "Elixir.") do
          String.to_existing_atom(mod)
        else
          String.to_existing_atom("Elixir." <> mod)
        end

      module
    rescue
      _ -> LemonChannels.Telegram.API
    end
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
    supervisor = async_supervisor_name()

    if is_pid(Process.whereis(supervisor)) do
      Task.Supervisor.start_child(supervisor, fn -> run_async_task(fun) end)
    else
      Task.start(fn -> run_async_task(fun) end)
    end
  rescue
    _ -> :ok
  end

  defp start_async_task(_state, _fun), do: :ok

  defp run_async_task(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp async_supervisor_name, do: LemonChannels.Adapters.Telegram.AsyncSupervisor

  defp map_get(map, key), do: MapHelpers.get_key(map, key)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

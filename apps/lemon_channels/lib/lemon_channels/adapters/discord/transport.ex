defmodule LemonChannels.Adapters.Discord.Transport do
  @moduledoc """
  Discord transport that routes inbound events to LemonRouter through RouterBridge.
  Feature-complete with model picker, thinking, resume, cancel, trigger, cwd, and reactions.

  Events run in temporary supervised tasks, in arrival order, so slow platform I/O
  never occupies the transport mailbox. Failed events are not replayed.
  """

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Discord.{
    Approval,
    FileOperations,
    Inbound,
    ModelCatalog,
    ModelPicker,
    ModelPolicyAdapter,
    Outbound,
    SlashCommands,
    ThreadResolver,
    TriggerMode,
    UserPrompt,
    VoiceHandler
  }

  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.BindingResolver
  alias LemonChannels.CommandAuthority
  alias LemonCore.Cwd
  alias LemonChannels.Discord.KnownTargetStore
  alias LemonChannels.ImageDownload
  alias LemonChannels.SubmissionOutcome
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope
  alias LemonCore.Dedupe.Ets

  alias LemonCore.{
    ChatStateStore,
    Event,
    InboundMessage,
    ProjectBindingStore,
    ResumeToken,
    RouterBridge,
    SessionKey,
    Store
  }

  alias Nostrum.Api.{ApplicationCommand, Interaction, Message, Thread, Webhook}

  @cancel_callback_prefix "lemon:cancel"
  @model_callback_prefix "lemon:model"
  @idle_keepalive_continue_prefix "lemon:idle:c:"
  @idle_keepalive_stop_prefix "lemon:idle:k:"

  @thinking_levels ~w(off minimal low medium high xhigh auto)
  @debounce_ms 1_000
  @default_dedupe_ttl 600_000
  @dedupe_table :lemon_channels_discord_dedupe
  @persistent_dedupe_scope "discord_inbound"
  @known_target_refresh_ms 30_000

  # Slash-command schemas live in SlashCommands; re-export the public surface the
  # adapter registration and tests depend on.
  defdelegate slash_commands, to: SlashCommands
  defdelegate redirect_command_schema, to: SlashCommands
  defdelegate kanban_command_schema, to: SlashCommands
  defdelegate checkpoint_command_schema, to: SlashCommands
  defdelegate rollback_command_schema, to: SlashCommands
  defdelegate media_command_schema, to: SlashCommands

  def slash_command_args_for_interaction(interaction) do
    name = interaction |> map_get(:data) |> map_get(:name)

    case name do
      "checkpoint" ->
        {:ok, %{command: "checkpoint", args: checkpoint_interaction_args(interaction)}}

      "rollback" ->
        {:ok, %{command: "rollback", args: checkpoint_interaction_args(interaction)}}

      "kanban" ->
        {:ok, %{command: "kanban", args: kanban_interaction_args(interaction)}}

      "media" ->
        {:ok, %{command: "media", args: media_interaction_args(interaction)}}

      _ ->
        {:error, :unsupported_command}
    end
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # GenServer Init
  # ============================================================================

  @impl true
  def init(opts) do
    LemonChannels.Registry.record_status("discord", :configured)
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}

    config =
      base
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    maybe_subscribe_exec_approvals()
    :ok = Ets.init(@dedupe_table)
    :ok = ThreadResolver.init()
    _ = :ets.delete_all_objects(@dedupe_table)

    data = %{
      transport_pid: self(),
      account_id: cfg_get(config, :account_id, "default"),
      allowed_guild_ids: parse_allowed_ids(cfg_get(config, :allowed_guild_ids)),
      allowed_channel_ids: parse_allowed_channel_ids(cfg_get(config, :allowed_channel_ids)),
      unauthorized_dm_behavior: cfg_get(config, :unauthorized_dm_behavior, "ignore"),
      deny_unbound_channels: cfg_get(config, :deny_unbound_channels, false),
      bot_user_id: nil,
      model_pickers: %{},
      buffers: %{},
      reaction_runs: %{},
      pending_new: %{},
      debounce_ms: cfg_get(config, :debounce_ms, @debounce_ms),
      dedupe_ttl_ms: cfg_get(config, :dedupe_ttl_ms, @default_dedupe_ttl),
      files: cfg_get(config, :files, %{})
    }

    {:ok, %{data: data, queue: :queue.new(), task: nil}}
  end

  # ============================================================================
  # GenServer Handlers
  # ============================================================================

  @impl true
  def handle_call({:update_allowlist, op, channel_id}, _from, state)
      when op in [:add, :remove] and is_integer(channel_id) do
    data = LemonChannels.Pairing.put_allowlist("discord", state.data, channel_id, op)
    {:reply, :ok, %{state | data: data}}
  end

  @impl true
  def handle_info({ref, {:noreply, data}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    # Pairing changes may arrive while I/O is in flight; never overwrite them.
    data = %{data | allowed_channel_ids: state.data.allowed_channel_ids}
    {:noreply, dispatch_next(%{state | data: data, task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %{ref: ref}} = state) do
    LemonChannels.Registry.record_status("discord", {:error, :event_failed})
    Logger.warning("discord event task failed; event will not be replayed")
    {:noreply, dispatch_next(%{state | task: nil})}
  end

  def handle_info({:discord_subscription, action, topic}, state) do
    case action do
      :subscribe -> LemonCore.Bus.subscribe(topic)
      :unsubscribe -> LemonCore.Bus.unsubscribe(topic)
    end

    {:noreply, state}
  end

  # Discord drops an interaction not acknowledged within 3 s, so the ack is
  # sent from its own task on arrival rather than behind queued events. The
  # acknowledged interaction then joins the queue; its replies become edits
  # and follow-ups.
  def handle_info({:discord_event, {:INTERACTION_CREATE, interaction, ws}} = event, state) do
    case defer_kind(interaction) do
      nil -> {:noreply, dispatch_next(%{state | queue: :queue.in(event, state.queue)})}
      kind -> {:noreply, start_ack(state, interaction, ws, kind)}
    end
  end

  def handle_info({:discord_interaction_acked, interaction, ws}, state) do
    event = {:discord_event, {:INTERACTION_CREATE, interaction, ws}}
    {:noreply, dispatch_next(%{state | queue: :queue.in(event, state.queue)})}
  end

  def handle_info(event, state) do
    {:noreply, dispatch_next(%{state | queue: :queue.in(event, state.queue)})}
  end

  defp defer_kind(interaction) do
    case map_get(interaction, :type) do
      2 -> :command
      3 -> :component
      _ -> nil
    end
  end

  defp start_ack(state, interaction, ws, kind) do
    owner = self()
    ack = if kind == :command, do: %{type: 5, data: %{flags: 64}}, else: %{type: 6}

    case LemonCore.TaskSupervisor.start_child(
           LemonChannels.Adapters.Discord.AsyncSupervisor,
           fn ->
             case safe_interaction_response(interaction, ack) do
               result when result in [:ok, {:ok}] or elem(result, 0) == :ok ->
                 deferred = %{kind: kind, claim: :atomics.new(1, [])}

                 send(
                   owner,
                   {:discord_interaction_acked, Map.put(interaction, :lemon_deferred, deferred),
                    ws}
                 )

               _error ->
                 LemonChannels.Registry.record_status(
                   "discord",
                   {:error, :interaction_ack_failed}
                 )

                 Logger.warning("discord interaction acknowledgement failed; not handled")
             end
           end
         ) do
      {:ok, _pid} ->
        state

      {:error, _reason} ->
        LemonChannels.Registry.record_status("discord", {:error, :event_failed})
        Logger.warning("discord interaction ack admission failed; not handled")
        state
    end
  end

  @impl true
  def terminate(_reason, %{task: %{pid: pid}}) do
    Task.Supervisor.terminate_child(LemonChannels.Adapters.Discord.AsyncSupervisor, pid)
  end

  def terminate(_reason, _state), do: :ok

  defp dispatch_next(%{task: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, event}, queue} ->
        owner = self()
        data = state.data

        case LemonCore.TaskSupervisor.async_nolink(
               LemonChannels.Adapters.Discord.AsyncSupervisor,
               fn ->
                 Process.put(:discord_transport, owner)
                 process_event(event, data)
               end
             ) do
          {:ok, task} ->
            %{state | task: task, queue: queue}

          {:error, _reason} ->
            LemonChannels.Registry.record_status("discord", {:error, :event_failed})
            Logger.warning("discord event task admission failed; event will not be replayed")
            dispatch_next(%{state | queue: queue})
        end

      {:empty, _queue} ->
        state
    end
  end

  defp dispatch_next(state), do: state

  defp start_task(fun) do
    owner = Process.get(:discord_transport, self())

    case LemonCore.TaskSupervisor.start_child(
           LemonChannels.Adapters.Discord.AsyncSupervisor,
           fn ->
             Process.put(:discord_transport, owner)
             fun.()
           end
         ) do
      {:ok, _pid} = result ->
        result

      {:error, _reason} = error ->
        Logger.warning("discord background task admission failed; work will not be replayed")
        error
    end
  end

  defp subscription(action, topic) do
    case Process.get(:discord_transport) do
      nil -> apply(LemonCore.Bus, action, [topic])
      owner -> send(owner, {:discord_subscription, action, topic})
    end
  end

  @doc false
  def process_event({:discord_event, {:READY, payload, _ws_state}}, state) do
    _ = register_slash_commands()

    bot_user_id =
      payload
      |> map_get(:user)
      |> map_get(:id)
      |> parse_id()

    {:noreply, %{state | bot_user_id: bot_user_id}}
  end

  def process_event({:discord_event, {:MESSAGE_CREATE, message, _ws_state}}, state) do
    state = maybe_handle_message(message, state)
    {:noreply, state}
  end

  def process_event({:discord_event, {:INTERACTION_CREATE, interaction, _ws_state}}, state) do
    state = maybe_handle_interaction(interaction, state)
    {:noreply, state}
  end

  # Debounce flush for buffered messages
  def process_event({:debounce_flush, scope_key, debounce_ref}, state) do
    {buffer, buffers} = Map.pop(state.buffers, scope_key)

    state =
      cond do
        buffer && buffer.debounce_ref == debounce_ref ->
          updated_state = submit_buffer(buffer, state)
          %{updated_state | buffers: buffers}

        buffer ->
          %{state | buffers: Map.put(state.buffers, scope_key, buffer)}

        true ->
          state
      end

    {:noreply, state}
  end

  # Run completion events for reaction updates and /new cleanup
  def process_event(%LemonCore.Event{type: :run_completed, meta: meta} = event, state) do
    run_id = (meta || %{})[:run_id] || (meta || %{})["run_id"]
    session_key = (meta || %{})[:session_key] || (meta || %{})["session_key"]

    # Handle /new command completion
    state =
      case run_id && Map.get(state.pending_new, run_id) do
        %{session_key: sk, channel_id: channel_id, thread_id: thread_id} = pending ->
          _ = safe_delete_chat_state(sk)

          ok? = run_completed_ok?(event)

          msg0 =
            if ok?,
              do: "Started a new session.",
              else: "Started a new session (memory recording failed)."

          scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
          msg = started_new_session_message(state, scope, sk, pending[:project], msg0)
          _ = send_channel_message(thread_id || channel_id, msg)

          topic = LemonCore.Bus.run_topic(run_id)
          _ = subscription(:unsubscribe, topic)

          %{state | pending_new: Map.delete(state.pending_new, run_id)}

        _ ->
          state
      end

    # Handle reaction updates for regular runs
    # Note: session_key may be nil in event.meta since the engine event doesn't always include it.
    # Fall back to finding the matching reaction_run by iterating tracked sessions.
    matched_sk =
      cond do
        is_binary(session_key) and Map.has_key?(state.reaction_runs, session_key) ->
          session_key

        # If session_key not in event meta, find first tracked reaction_run
        # (we receive this event because we subscribed to the session topic)
        map_size(state.reaction_runs) > 0 ->
          state.reaction_runs |> Map.keys() |> List.first()

        true ->
          nil
      end

    state =
      case matched_sk && Map.get(state.reaction_runs, matched_sk) do
        %{channel_id: channel_id, user_msg_id: user_msg_id} ->
          ok? = run_completed_ok?(event)
          reaction_emoji = if ok?, do: "✅", else: "❌"

          _ =
            start_task(fn ->
              # Remove 👀 and add result reaction
              _ = Outbound.delete_own_reaction(channel_id, user_msg_id, "👀")
              _ = Outbound.create_reaction(channel_id, user_msg_id, reaction_emoji)
            end)

          topic = LemonCore.Bus.session_topic(matched_sk)
          _ = subscription(:unsubscribe, topic)

          %{state | reaction_runs: Map.delete(state.reaction_runs, matched_sk)}

        _ ->
          state
      end

    {:noreply, state}
  end

  # Approval requests
  def process_event(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    _ = Approval.send(state, payload)
    {:noreply, state}
  end

  def process_event(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  def process_event({:discord_event, {:THREAD_CREATE, thread, _ws_state}}, state) do
    state = maybe_handle_thread_create(thread, state)
    {:noreply, state}
  end

  def process_event({:discord_prepared_message, %InboundMessage{} = inbound}, state) do
    {:noreply, continue_message(state, inbound)}
  rescue
    error ->
      Logger.warning("discord inbound message handling failed: #{inspect(error.__struct__)}")
      {:noreply, state}
  end

  def process_event(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp maybe_handle_message(message, state) do
    with true <- not_self_message?(message, state),
         {:ok, inbound} <- normalize_message_inbound(message, state),
         :ok <- authorize_message(inbound, state),
         true <- binding_allowed?(inbound, state),
         {:new, dedupe_ref} <- check_dedupe(inbound, state) do
      inbound = put_submission_dedupe_ref(inbound, dedupe_ref)

      if (inbound.meta[:attachments] || []) == [] do
        continue_message(state, inbound)
      else
        prepare_media(inbound)
        state
      end
    else
      {:unauthorized, inbound} ->
        maybe_reply_pairing(inbound, state)
        state

      :seen ->
        Logger.debug("discord: dropping duplicate message")
        state

      {:error, :channel_unresolved} ->
        # Routing under a guessed key would split the thread's session.
        LemonChannels.Registry.record_status("discord", {:error, :channel_unresolved})
        Logger.warning("discord message channel could not be resolved; message not routed")
        state

      _ ->
        state
    end
  rescue
    error ->
      Logger.warning("discord inbound message handling failed: #{inspect(error)}")
      state
  end

  # Transcription and image downloads run beside the serial event queue; the
  # prepared message comes back as its own event.
  defp prepare_media(inbound) do
    owner = Process.get(:discord_transport, self())

    case start_task(fn ->
           {inbound, voice_errors} = VoiceHandler.transcribe(inbound)

           Enum.each(voice_errors, fn text ->
             Outbound.send_with_components(
               inbound.meta[:thread_id] || inbound.meta[:channel_id],
               text,
               [],
               []
             )
           end)

           send(owner, {:discord_prepared_message, Inbound.attach_images(inbound)})
         end) do
      {:ok, _pid} ->
        :ok

      {:error, _reason} ->
        LemonChannels.Registry.record_status("discord", {:error, :event_failed})
        :ok
    end
  end

  defp continue_message(state, inbound) do
    _ = maybe_index_known_target(state, inbound)

    if LemonChannels.UserPromptSurface.capture(inbound) == true,
      do: state,
      else: handle_inbound_message(state, inbound)
  end

  defp authorize_message(inbound, state) do
    if allowed_inbound?(inbound, state), do: :ok, else: {:unauthorized, inbound}
  end

  defp maybe_reply_pairing(inbound, %{unauthorized_dm_behavior: "pair"}) do
    with {:ok, text} <- LemonChannels.Pairing.reply("discord", inbound) do
      api = cfg_get(LemonChannels.GatewayConfig.get(:discord, %{}), :api_mod, Message)

      api.create(
        inbound.meta[:channel_id],
        %{content: text, allowed_mentions: safe_allowed_mentions()}
      )
    end
  rescue
    _ -> Logger.warning("discord pairing reply failed")
  catch
    _kind, _reason -> Logger.warning("discord pairing reply failed")
  end

  defp maybe_reply_pairing(_inbound, _state), do: :ok

  defp check_dedupe(inbound, state) do
    key = TransportShared.inbound_message_dedupe_key(inbound)

    case Ets.check_and_mark(@dedupe_table, key, state.dedupe_ttl_ms) do
      :seen ->
        :seen

      :new ->
        case check_and_mark_persistent_dedupe(inbound, key, state) do
          :unavailable ->
            # Not admitted and not claimed: a later redelivery is checked again.
            Logger.warning("discord: dropping message; ingress dedupe receipt unavailable")
            _ = Ets.forget(@dedupe_table, key)
            :unavailable

          seen_or_new ->
            seen_or_new
        end
    end
  end

  # The receipt is claimed with an atomic insert and read strictly. An
  # unreadable receipt, or a claim whose write outcome is unknown, never
  # admits the message: replaying a delivered message would submit it twice.
  defp check_and_mark_persistent_dedupe(inbound, key, state) do
    store_key = persistent_dedupe_key(inbound, key)
    receipt = %{"inserted_at_ms" => Event.now_ms()}
    ref = %{memory_key: key, persistent_key: store_key, receipt: receipt}

    case Store.put_new(:idempotency, store_key, receipt) do
      :ok ->
        {:new, ref}

      {:error, :exists} ->
        renew_expired_dedupe(store_key, ref, state)

      {:error, _reason} ->
        # The insert may have landed; nothing was submitted, so drop only our
        # own exact receipt.
        _ = Store.compare_and_delete(:idempotency, store_key, receipt)
        :unavailable
    end
  end

  defp renew_expired_dedupe(store_key, %{receipt: receipt} = ref, state) do
    case Store.fetch(:idempotency, store_key) do
      {:ok, %{"inserted_at_ms" => inserted_at_ms} = existing} when is_integer(inserted_at_ms) ->
        cond do
          receipt["inserted_at_ms"] - inserted_at_ms <= state.dedupe_ttl_ms ->
            :seen

          Store.compare_and_swap(:idempotency, store_key, existing, receipt) == :ok ->
            {:new, ref}

          true ->
            :seen
        end

      {:ok, nil} ->
        # Released after a retry-safe failure; claim again on redelivery.
        :unavailable

      {:ok, _unknown_receipt} ->
        :seen

      {:error, _reason} ->
        :unavailable
    end
  end

  defp persistent_dedupe_key(inbound, key) do
    account_id = inbound.account_id || "default"
    encoded = key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    "#{@persistent_dedupe_scope}:#{account_id}:#{encoded}"
  end

  defp put_submission_dedupe_ref(inbound, dedupe_ref) do
    meta = inbound.meta || %{}
    refs = [dedupe_ref | List.wrap(meta[:transport_dedupe_refs])]
    %{inbound | meta: Map.put(meta, :transport_dedupe_refs, refs)}
  end

  defp merge_submission_dedupe_refs(inbound, previous_inbound) do
    previous_refs = List.wrap((previous_inbound.meta || %{})[:transport_dedupe_refs])

    Enum.reduce(previous_refs, inbound, fn dedupe_ref, acc ->
      put_submission_dedupe_ref(acc, dedupe_ref)
    end)
  end

  defp pop_submission_dedupe_refs(inbound) do
    meta = inbound.meta || %{}

    {List.wrap(meta[:transport_dedupe_refs]),
     %{inbound | meta: Map.delete(meta, :transport_dedupe_refs)}}
  end

  defp forget_submission_dedupe(refs) do
    Enum.each(refs, fn
      %{memory_key: memory_key, persistent_key: persistent_key, receipt: receipt} ->
        _ = Ets.forget(@dedupe_table, memory_key)
        _ = Store.compare_and_delete(:idempotency, persistent_key, receipt)

      _ ->
        :ok
    end)

    :ok
  end

  defp handle_inbound_message(state, inbound) do
    text = inbound.message.text || ""

    # Auto-put attachments if enabled (before any other processing)
    _ =
      if FileOperations.should_auto_put?(state, inbound) do
        start_task(fn -> FileOperations.handle_attachment_auto_put(state, inbound) end)
      end

    case Regex.run(~r/^\/(approve|deny)(?:\s+(.*))?$/s, String.trim(text)) do
      [_, command | rest] ->
        handle_approval_message(state, inbound, command, List.first(rest) || "")

      _ ->
        if should_ignore_for_trigger?(state, inbound, text) do
          state
        else
          enqueue_buffer(state, inbound)
        end
    end
  end

  defp handle_approval_message(state, inbound, command, args) do
    meta = inbound.meta

    interaction =
      ThreadResolver.with_location(%{guild_id: meta[:guild_id]}, %{
        channel_id: meta[:channel_id],
        thread_id: meta[:thread_id]
      })

    context = %{
      surface: "discord",
      account_id: state.account_id,
      approval_authorize: Approval.text_authorizer(state, interaction)
    }

    {_, text} = LemonChannels.PortableCommand.handle(command, args, context)
    _ = Outbound.send_with_components(meta[:thread_id] || meta[:channel_id], text, [], [])
    state
  end

  defp submit_buffer(buffer, state) do
    messages = Enum.reverse(buffer.messages)
    joined_text = messages |> Enum.map(& &1.text) |> Enum.join("\n\n")
    last = List.last(messages) || %{}

    inbound = %{
      buffer.inbound
      | message: Map.put(buffer.inbound.message || %{}, :text, joined_text)
    }

    inbound =
      if last[:reply_to_id],
        do: put_in(inbound, [Access.key(:message), :reply_to_id], last[:reply_to_id]),
        else: inbound

    submit_inbound_now(state, inbound)
  end

  defp enqueue_buffer(state, inbound) do
    scope_key = buffer_scope_key(inbound)
    existing = Map.get(state.buffers, scope_key)
    inbound = if existing, do: ImageDownload.merge(inbound, existing.inbound), else: inbound
    msg_entry = %{text: inbound.message.text || "", reply_to_id: inbound.message.reply_to_id}

    debounce_ref = make_ref()
    owner = Map.get(state, :transport_pid, self())
    Process.send_after(owner, {:debounce_flush, scope_key, debounce_ref}, state.debounce_ms)

    buffer =
      if existing do
        inbound = merge_submission_dedupe_refs(inbound, existing.inbound)

        %{
          existing
          | messages: [msg_entry | existing.messages],
            debounce_ref: debounce_ref,
            inbound: inbound
        }
      else
        %{
          messages: [msg_entry],
          debounce_ref: debounce_ref,
          inbound: inbound
        }
      end

    %{state | buffers: Map.put(state.buffers, scope_key, buffer)}
  end

  defp buffer_scope_key(inbound) do
    channel_id = inbound.meta[:channel_id]
    thread_id = inbound.meta[:thread_id]

    session_key =
      inbound.meta[:session_key] || inbound.meta[:user_id] || get_in(inbound, [:sender, :id])

    {channel_id, thread_id, session_key}
  end

  defp submit_inbound_now(state, inbound) do
    {_outcome, state} = submit_inbound_now_with_result(state, inbound)
    state
  end

  defp submit_inbound_now_with_result(state, inbound) do
    {queue_override, inbound} = apply_queue_prefix(inbound)
    {dedupe_refs, inbound} = pop_submission_dedupe_refs(inbound)

    channel_id = inbound.meta[:channel_id]
    thread_id = inbound.meta[:thread_id]
    user_msg_id = inbound.meta[:user_msg_id]

    # The message itself is the progress target. The reaction is added only
    # after the router accepts the run, so a rejected submission never looks
    # queued to the user.
    progress_msg_id =
      if is_integer(channel_id) and is_integer(user_msg_id), do: user_msg_id, else: nil

    scope =
      if is_integer(channel_id),
        do: %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id},
        else: nil

    session_key = build_session_key(state, inbound, scope)

    {model_hint, model_scope} = resolve_model_hint(state, session_key, channel_id, thread_id)
    {thinking_hint, thinking_scope} = resolve_thinking_hint(state, channel_id, thread_id)

    meta =
      inbound.meta
      |> Map.put(:session_key, session_key)
      |> Map.put(:progress_msg_id, progress_msg_id)
      |> Map.put(:user_msg_id, user_msg_id)
      |> Map.put(:status_msg_id, nil)
      |> Map.put(:topic_id, thread_id)
      |> maybe_put(:model, model_hint)
      |> maybe_put(:model_scope, model_scope)
      |> maybe_put(:thinking_level, thinking_hint)
      |> maybe_put(:thinking_scope, thinking_scope)
      |> maybe_put(:queue_mode, queue_override)

    meta =
      case meta[:resume] do
        %ResumeToken{engine: "lemon"} = resume -> Map.put(meta, :resume, resume)
        _ -> Map.delete(meta, :resume)
      end

    # Apply a native resume selected by /resume. Selections are keyed by the
    # sender's full session key, so one user's choice never resumes another
    # user's prompt in the same channel or thread. Stale vendor selections
    # remain stored for rollback, but never affect a native channel run. An
    # unreadable selection is kept and the submission rejected, never dropped.
    meta =
      if is_nil(meta[:resume]) do
        case LemonCore.Store.fetch(:discord_selected_resume, session_key) do
          {:ok, %ResumeToken{engine: "lemon"} = resume} ->
            _ = LemonCore.Store.delete(:discord_selected_resume, session_key)
            Map.put(meta, :resume, resume)

          {:ok, _none_or_vendor} ->
            meta

          {:error, _reason} ->
            Map.put(meta, :selected_resume_unavailable, true)
        end
      else
        meta
      end

    case ResumeSelection.extract_explicit_resume_and_strip(inbound.message.text) do
      {:unsupported, engine} ->
        _ = send_channel_message(thread_id || channel_id, unsupported_resume_message(engine))
        {:handled, state}

      {%ResumeToken{engine: "lemon"} = explicit_resume, stripped_prompt} ->
        inbound =
          %{
            inbound
            | meta:
                if(is_nil(meta[:resume]), do: Map.put(meta, :resume, explicit_resume), else: meta),
              message: Map.put(inbound.message, :text, stripped_prompt)
          }

        finish_submission(state, inbound, dedupe_refs)

      {%ResumeToken{engine: engine}, _stripped_prompt} ->
        _ = send_channel_message(thread_id || channel_id, unsupported_resume_message(engine))
        {:handled, state}

      {_explicit_resume, stripped_prompt} ->
        inbound = %{
          inbound
          | meta: meta,
            message: Map.put(inbound.message, :text, stripped_prompt)
        }

        finish_submission(state, inbound, dedupe_refs)
    end
  end

  defp finish_submission(state, inbound, dedupe_refs) do
    result =
      if inbound.meta[:selected_resume_unavailable],
        do: {:error, :resume_unavailable},
        else: route_to_router(state, inbound)

    case result do
      :ok ->
        {:ok, track_accepted_submission(state, inbound)}

      {:error, _} = error ->
        if SubmissionOutcome.retry_safe?(error), do: forget_submission_dedupe(dedupe_refs)
        maybe_report_submission_failure(inbound, error)
        {error, state}
    end
  end

  defp track_accepted_submission(state, inbound) do
    meta = inbound.meta || %{}
    channel_id = meta[:channel_id]
    thread_id = meta[:thread_id]
    user_msg_id = meta[:user_msg_id]
    session_key = meta[:session_key]
    # Reactions address the message where it was posted: the thread, if any.
    message_channel_id = thread_id || channel_id

    reaction_added? =
      if is_integer(message_channel_id) and is_integer(user_msg_id) do
        match?({:ok, _}, Outbound.create_reaction(message_channel_id, user_msg_id, "👀"))
      else
        false
      end

    if reaction_added? and is_binary(session_key) do
      maybe_subscribe_to_session(session_key)

      reaction_run = %{
        channel_id: message_channel_id,
        thread_id: thread_id,
        user_msg_id: user_msg_id,
        session_key: session_key
      }

      %{state | reaction_runs: Map.put(state.reaction_runs, session_key, reaction_run)}
    else
      state
    end
  end

  defp maybe_report_submission_failure(inbound, error) do
    meta = inbound.meta || %{}

    if meta[:source] != :slash and is_integer(meta[:channel_id]) do
      _ =
        Outbound.send_with_components(
          meta[:channel_id],
          submission_failure_message(error),
          [],
          []
        )
    end

    :ok
  end

  defp submission_failure_message(error) do
    if SubmissionOutcome.uncertain?(error) do
      "I couldn't confirm whether that request was accepted. Check the run status before retrying."
    else
      "I couldn't queue that request. Please try again."
    end
  end

  defp unsupported_resume_message(engine) do
    "Resume engine #{inspect(engine)} is not supported here. Use a Lemon resume token instead."
  end

  # Text-prefix forms of the portable queue commands. A bare prefix carries no
  # prompt and is left alone for the command surface to explain. Discord has no
  # `allow_queue_override` gate, matching its existing /redirect behavior.
  defp apply_queue_prefix(inbound) do
    case parse_queue_prefix(inbound.message && Map.get(inbound.message, :text)) do
      {queue_mode, rest} ->
        {queue_mode, %{inbound | message: Map.put(inbound.message, :text, rest)}}

      :none ->
        {nil, inbound}
    end
  end

  defp parse_queue_prefix(text) when is_binary(text) do
    trimmed = String.trim_leading(text)

    case Regex.run(~r/^(?:(!redirect)|\/(redirect|steer|queue|q))(?:\s+(.*))?$/is, trimmed) do
      [_, bang_redirect, slash_command, rest] ->
        case String.trim_leading(rest) do
          "" -> :none
          prompt -> {queue_mode_for_prefix(bang_redirect, slash_command), prompt}
        end

      _ ->
        :none
    end
  end

  defp parse_queue_prefix(_text), do: :none

  defp queue_mode_for_prefix(bang_redirect, _slash_command)
       when is_binary(bang_redirect) and bang_redirect != "",
       do: :redirect

  defp queue_mode_for_prefix(_bang_redirect, slash_command) do
    case String.downcase(slash_command || "") do
      "redirect" -> :redirect
      "steer" -> :steer
      command when command in ["queue", "q"] -> :followup
    end
  end

  # ============================================================================
  # Interaction Handling (Slash Commands + Component Interactions)
  # ============================================================================

  defp maybe_handle_interaction(interaction, state) do
    case ThreadResolver.put_location(interaction) do
      {:ok, interaction} ->
        dispatch_interaction(interaction, state)

      {:error, :channel_unresolved} ->
        Logger.warning("discord interaction channel could not be resolved; not handled")

        respond_ephemeral(
          interaction,
          "I couldn't look up this channel on Discord, so nothing was done. Try again."
        )

        state
    end
  rescue
    error ->
      Logger.warning("discord interaction handling failed: #{inspect(error)}")
      state
  end

  defp dispatch_interaction(interaction, state) do
    case map_get(interaction, :type) do
      # Application Command (slash command)
      2 -> handle_slash_command(interaction, state)
      # Message Component (button, select menu)
      3 -> handle_component_interaction(interaction, state)
      _ -> state
    end
  end

  defp handle_slash_command(interaction, state) do
    name = interaction |> map_get(:data) |> map_get(:name)
    inbound = interaction_to_inbound(interaction, "/#{name || "unknown"}", state)

    cond do
      not (allowed_inbound?(inbound, state) and binding_allowed?(inbound, state)) ->
        respond_ephemeral(interaction, "This command is not available in this Discord location.")
        state

      CommandAuthority.authorize(name, CommandAuthority.discord_admin?(interaction)) != :ok ->
        respond_ephemeral(interaction, CommandAuthority.refusal_message())
        state

      true ->
        dispatch_slash_command(name, interaction, state)
    end
  end

  defp dispatch_slash_command(name, interaction, state) do
    case name do
      "lemon" ->
        handle_lemon_interaction(interaction, state)

      "session" ->
        handle_session_interaction(interaction, state)

      "model" ->
        handle_model_interaction(interaction, state)

      "thinking" ->
        handle_thinking_interaction(interaction, state)

      "reasoning" ->
        handle_thinking_interaction(interaction, state)

      "resume" ->
        handle_resume_interaction(interaction, state)

      "redirect" ->
        handle_redirect_interaction(interaction, state)

      "queue" ->
        handle_queue_interaction(interaction, state, :followup)

      "q" ->
        handle_queue_interaction(interaction, state, :followup)

      "steer" ->
        handle_queue_interaction(interaction, state, :steer)

      "cancel" ->
        handle_cancel_interaction(interaction, state)

      "stop" ->
        handle_cancel_interaction(interaction, state)

      "reset" ->
        handle_new_session(interaction, state, option_value(interaction, "project"))

      command
      when command in ~w(status usage agents tasks compress commands help bg btw approve deny) ->
        handle_portable_interaction(interaction, state, command)

      "checkpoint" ->
        handle_checkpoint_interaction(interaction, state)

      "rollback" ->
        handle_rollback_interaction(interaction, state)

      "goal" ->
        handle_goal_interaction(interaction, state)

      "kanban" ->
        handle_kanban_interaction(interaction, state)

      "media" ->
        handle_media_interaction(interaction, state)

      "trigger" ->
        handle_trigger_interaction(interaction, state)

      "cwd" ->
        handle_cwd_interaction(interaction, state)

      "topic" ->
        handle_topic_interaction(interaction, state)

      "file" ->
        handle_file_interaction(interaction, state)

      _ ->
        respond_ephemeral(interaction, "Unknown command")
        state
    end
  end

  defp handle_component_interaction(interaction, state) do
    custom_id = interaction |> map_get(:data) |> map_get(:custom_id)
    custom_id = if is_binary(custom_id), do: custom_id, else: ""
    values = interaction |> map_get(:data) |> map_get(:values) || []

    cond do
      String.starts_with?(custom_id, "ask:") ->
        inbound = interaction_to_inbound(interaction, "", state)

        result =
          if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state),
            do: UserPrompt.handle(state, interaction),
            else: {:error, :wrong_user}

        notice =
          case result do
            :ok -> "Recorded"
            {:error, :wrong_user} -> "Only the user who started this run may answer here."
            {:error, :empty} -> "Choose at least one option first."
            _ -> "expired"
          end

        respond_ephemeral(interaction, notice)
        state

      component_command(custom_id) != nil and
          not component_allowed?(interaction, custom_id, state) ->
        respond_ephemeral(
          interaction,
          "This control is not available in this Discord location; nothing changed."
        )

        state

      String.starts_with?(custom_id, @cancel_callback_prefix <> ":") ->
        run_id = String.trim_leading(custom_id, @cancel_callback_prefix <> ":")

        with_owned_run(interaction, run_id, state, fn ->
          handle_cancel_component(interaction, run_id)
        end)

      String.starts_with?(custom_id, @idle_keepalive_continue_prefix) ->
        run_id = String.trim_leading(custom_id, @idle_keepalive_continue_prefix)

        with_owned_run(interaction, run_id, state, fn ->
          handle_keepalive_component(interaction, run_id, :continue)
        end)

      String.starts_with?(custom_id, @idle_keepalive_stop_prefix) ->
        run_id = String.trim_leading(custom_id, @idle_keepalive_stop_prefix)

        with_owned_run(interaction, run_id, state, fn ->
          handle_keepalive_component(interaction, run_id, :cancel)
        end)

      String.starts_with?(custom_id, @model_callback_prefix) ->
        handle_model_component(interaction, state, custom_id, values)

      true ->
        case Approval.handle(state, interaction) do
          :ok ->
            acknowledge_interaction(interaction)

          {:error, :run_ended} ->
            respond_ephemeral(
              interaction,
              "This approval expired because its run ended; nothing was approved."
            )

          {:error, reason} when reason in [:not_pending, :expired, :already_resolved] ->
            respond_ephemeral(
              interaction,
              "This approval is no longer pending; nothing changed. Submit a new request if approval is still needed."
            )

          {:error, reason}
          when reason in [
                 :rejected,
                 :invalid_callback,
                 :wrong_target,
                 :invalid_target,
                 :invalid_pending
               ] ->
            respond_ephemeral(
              interaction,
              "This approval cannot be used here; nothing changed. Open the approval in its original conversation."
            )

          {:error, :outcome_unknown} ->
            respond_ephemeral(
              interaction,
              "Approval outcome unknown: the store did not confirm it. The action did not run; check the approval status before answering again."
            )

          error ->
            Logger.warning("Discord approval unavailable: #{inspect(error)}")
            respond_ephemeral(interaction, "Approval is unavailable right now. Try again.")
        end

        state
    end
  end

  # ============================================================================
  # /lemon Command
  # ============================================================================

  defp handle_lemon_interaction(interaction, state) do
    prompt = option_value(interaction, "prompt")

    if is_binary(prompt) and String.trim(prompt) != "" do
      inbound = interaction_to_inbound(interaction, prompt, state)

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        respond_to_submission(
          interaction,
          submit_inbound_now_with_result(state, inbound),
          "Queued"
        )
      else
        state
      end
    else
      respond_ephemeral(interaction, "Prompt cannot be empty.")
      state
    end
  end

  # ============================================================================
  # /redirect Command
  # ============================================================================

  defp handle_redirect_interaction(interaction, state) do
    correction = option_value(interaction, "correction")

    if is_binary(correction) and String.trim(correction) != "" do
      inbound = interaction_to_inbound(interaction, correction, state)
      inbound = %{inbound | meta: Map.put(inbound.meta, :queue_mode, :redirect)}

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        respond_to_submission(
          interaction,
          submit_inbound_now_with_result(state, inbound),
          "Redirecting…"
        )
      else
        state
      end
    else
      respond_ephemeral(interaction, "Correction cannot be empty.")
      state
    end
  end

  defp handle_queue_interaction(interaction, state, queue_mode)
       when queue_mode in [:followup, :steer] do
    prompt = option_value(interaction, "prompt")

    if is_binary(prompt) and String.trim(prompt) != "" do
      response = if(queue_mode == :steer, do: "Steering…", else: "Queued as follow-up")

      inbound = interaction_to_inbound(interaction, prompt, state)
      inbound = %{inbound | meta: Map.put(inbound.meta, :queue_mode, queue_mode)}

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        respond_to_submission(
          interaction,
          submit_inbound_now_with_result(state, inbound),
          response
        )
      else
        state
      end
    else
      respond_ephemeral(interaction, "Prompt cannot be empty.")
      state
    end
  end

  defp respond_to_submission(interaction, {outcome, state}, success_message) do
    message = if outcome == :ok, do: success_message, else: submission_failure_message(outcome)
    _ = respond_ephemeral(interaction, message)
    state
  end

  defp handle_portable_interaction(interaction, state, command) do
    args =
      case command do
        "help" -> option_value(interaction, "filter")
        "bg" -> option_value(interaction, "prompt")
        "btw" -> option_value(interaction, "question")
        name when name in ["approve", "deny"] -> option_value(interaction, "id")
        _ -> ""
      end

    inbound = interaction_to_inbound(interaction, "/#{command} #{args}", state)

    if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
      session_key = inbound.meta[:session_key]
      channel_id = inbound.meta[:channel_id]
      thread_id = inbound.meta[:thread_id]
      scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

      context = %{
        surface: "discord",
        account_id: state.account_id,
        approval_authorize: Approval.text_authorizer(state, interaction),
        session_key: session_key,
        cwd: BindingResolver.resolve_cwd(scope)
      }

      run = fn ->
        case LemonChannels.PortableCommand.handle(command, args, context) do
          {:ok, result} -> result
          {:error, message} -> message
        end
      end

      if command == "btw" do
        case start_task(fn ->
               respond_ephemeral(interaction, "Answering side question…")
               send_followup(interaction, run.())
             end) do
          {:ok, _pid} ->
            :ok

          {:error, _reason} ->
            respond_ephemeral(interaction, "Side question could not be started.")
        end
      else
        respond_ephemeral(interaction, run.())
      end
    else
      respond_ephemeral(interaction, "This command is not available in this Discord location.")
    end

    state
  end

  # ============================================================================
  # /session Command
  # ============================================================================

  defp handle_session_interaction(interaction, state) do
    sub = session_subcommand(interaction)

    case sub do
      "new" ->
        project_selector = nested_option_value(interaction, "new", "project")
        handle_new_session(interaction, state, project_selector)

      "info" ->
        session_key = interaction_session_key(interaction, state)
        channel_id = interaction_channel_id(interaction)
        thread_id = interaction_thread_id(interaction)
        scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

        {model_hint, model_scope} = resolve_model_hint(state, session_key, channel_id, thread_id)
        {thinking_hint, thinking_scope} = resolve_thinking_hint(state, channel_id, thread_id)

        model_line = format_model_line(model_hint, model_scope)
        thinking_line = ModelPolicyAdapter.format_thinking_line(thinking_hint, thinking_scope)
        cwd_line = resolve_cwd_display(scope)

        info =
          [
            "**Session Info**",
            "Session: `#{session_key}`",
            "Model: #{model_line}",
            "Thinking: #{thinking_line}",
            "CWD: #{cwd_line}",
            "Account: #{state.account_id || "default"}"
          ]
          |> Enum.join("\n")

        respond_ephemeral(interaction, info)

      _ ->
        respond_ephemeral(interaction, "Unknown /session subcommand")
    end

    state
  end

  defp handle_new_session(interaction, state, project_selector) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    user_id = interaction_user_id(interaction)
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    peer_kind = if is_integer(guild_id), do: :group, else: :dm

    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    agent_id = BindingResolver.resolve_agent_id(scope)

    session_key =
      session_key_for(
        agent_id,
        state.account_id,
        peer_kind,
        channel_id,
        user_id,
        thread_id,
        guild_id
      )

    # Handle project selection
    project_result =
      case normalize_blank(project_selector) do
        nil -> :noop
        sel -> maybe_select_project_for_scope(scope, sel)
      end

    case project_result do
      {:error, msg} ->
        respond_ephemeral(interaction, msg)

      _ ->
        # Fire-and-forget memory reflection before clearing the session
        spawn_memory_reflection_before_new(
          state,
          scope,
          session_key,
          interaction,
          channel_id,
          thread_id,
          user_id,
          peer_kind,
          agent_id
        )

        # Clear state
        _ = safe_delete_chat_state(session_key)
        _ = LemonCore.Store.delete(:discord_selected_resume, session_key)
        _ = ModelPolicyAdapter.delete_session_model_override(session_key)

        project = extract_project_info(project_result)

        msg =
          started_new_session_message(
            state,
            scope,
            session_key,
            project,
            "Started a new session."
          )

        respond_ephemeral(interaction, msg)
    end
  end

  defp spawn_memory_reflection_before_new(
         state,
         scope,
         session_key,
         interaction,
         channel_id,
         thread_id,
         _user_id,
         peer_kind,
         agent_id
       ) do
    inbound = %InboundMessage{
      channel_id: "discord",
      account_id: state.account_id,
      peer: %{
        kind: peer_kind,
        id: Integer.to_string(channel_id),
        thread_id: maybe_to_string(thread_id)
      },
      sender: %{
        id: maybe_to_string(interaction_user_id(interaction)),
        username: nil,
        display_name: nil
      },
      message: %{id: nil, text: nil, timestamp: System.system_time(:second), reply_to_id: nil},
      raw: interaction,
      meta: %{
        session_key: session_key,
        agent_id: agent_id,
        channel_id: channel_id,
        thread_id: thread_id
      }
    }

    start_task(fn ->
      MemoryReflection.submit_before_new(
        state,
        inbound,
        scope,
        session_key,
        channel_id,
        thread_id,
        nil,
        %{
          maybe_subscribe_to_run: fn _run_id -> :ok end,
          current_thread_generation: fn _state, _chat_id, _thread_id -> 0 end,
          maybe_put: &maybe_put/3
        }
      )
    end)
  end

  # ============================================================================
  # /model Command
  # ============================================================================

  defp handle_model_interaction(interaction, state) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    user_id = interaction_user_id(interaction)
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    peer_kind = if is_integer(guild_id), do: :group, else: :dm

    session_key =
      session_key_for(
        BindingResolver.resolve_agent_id(%ChatScope{
          transport: :discord,
          chat_id: channel_id,
          topic_id: thread_id
        }),
        state.account_id,
        peer_kind,
        channel_id,
        user_id,
        thread_id,
        guild_id
      )

    current_session_model = ModelPolicyAdapter.session_model_override(session_key)

    current_future_model =
      ModelPolicyAdapter.default_model_preference(state.account_id, channel_id, thread_id)

    providers = ModelCatalog.available_model_providers()

    if providers == [] do
      respond_ephemeral(interaction, "No models available.")
    else
      text = render_model_picker_text(current_session_model, current_future_model)
      components = ModelPicker.model_provider_components(providers, 0)

      respond_with_components(interaction, text, components, ephemeral: true)
    end

    state
  end

  defp handle_model_component(interaction, state, custom_id, values) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    user_id = interaction_user_id(interaction)
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    peer_kind = if is_integer(guild_id), do: :group, else: :dm

    session_key =
      session_key_for(
        BindingResolver.resolve_agent_id(%ChatScope{
          transport: :discord,
          chat_id: channel_id,
          topic_id: thread_id
        }),
        state.account_id,
        peer_kind,
        channel_id,
        user_id,
        thread_id,
        guild_id
      )

    case ModelPicker.parse_model_callback(custom_id, values) do
      {:select_provider, provider} ->
        models = ModelCatalog.models_for_provider(provider)

        if models == [] do
          update_interaction(
            interaction,
            "No models available for #{provider}.",
            ModelPicker.model_provider_components(ModelCatalog.available_model_providers(), 0)
          )
        else
          update_interaction(
            interaction,
            "Provider: **#{provider}**\nChoose a model:",
            ModelPicker.model_list_components(provider, models, 0)
          )
        end

      {:providers, page} ->
        providers = ModelCatalog.available_model_providers()

        current_future_model =
          ModelPolicyAdapter.default_model_preference(state.account_id, channel_id, thread_id)

        text = render_model_picker_text(nil, current_future_model)

        update_interaction(
          interaction,
          text,
          ModelPicker.model_provider_components(providers, page)
        )

      {:provider, provider, page} ->
        models = ModelCatalog.models_for_provider(provider)

        update_interaction(
          interaction,
          "Provider: **#{provider}**\nChoose a model:",
          ModelPicker.model_list_components(provider, models, page)
        )

      {:choose, provider, index} ->
        case ModelCatalog.model_at_index(provider, index) do
          nil ->
            acknowledge_interaction(interaction)

          model ->
            update_interaction(
              interaction,
              "Selected: **#{ModelCatalog.model_label(model)}**\nApply to:",
              ModelPicker.model_scope_components(provider, index)
            )
        end

      {:set, scope_type, provider, index} ->
        case ModelCatalog.model_at_index(provider, index) do
          nil ->
            acknowledge_interaction(interaction)

          model ->
            model_value = ModelCatalog.model_spec(model)
            _ = ModelPolicyAdapter.put_session_model_override(session_key, model_value)

            if scope_type == :future do
              _ =
                ModelPolicyAdapter.put_default_model_preference(
                  state.account_id,
                  channel_id,
                  thread_id,
                  model_value
                )
            end

            text =
              if scope_type == :future,
                do:
                  "Default model set to **#{ModelCatalog.model_label(model)}** for all future sessions.",
                else: "Model set to **#{ModelCatalog.model_label(model)}** for this session."

            update_interaction(interaction, text, [])
        end

      :close ->
        update_interaction(interaction, "Model picker closed.", [])

      _ ->
        acknowledge_interaction(interaction)
    end

    state
  end

  # ============================================================================
  # /thinking Command
  # ============================================================================

  defp handle_thinking_interaction(interaction, state) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    account_id = state.account_id || "default"
    level_arg = option_value(interaction, "level") || "status"
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

    case normalize_thinking_arg(level_arg) do
      :status ->
        respond_ephemeral(interaction, render_thinking_status(state, scope))

      :clear ->
        had? =
          ModelPolicyAdapter.clear_default_thinking_preference(account_id, channel_id, thread_id)

        respond_ephemeral(interaction, render_thinking_cleared(scope, had?))

      {:set, level} ->
        :ok =
          ModelPolicyAdapter.put_default_thinking_preference(
            account_id,
            channel_id,
            thread_id,
            level
          )

        respond_ephemeral(interaction, render_thinking_set(scope, level))

      :invalid ->
        respond_ephemeral(interaction, thinking_usage())
    end

    state
  end

  # ============================================================================
  # /resume Command
  # ============================================================================

  defp handle_resume_interaction(interaction, state) do
    selector = option_value(interaction, "selector")
    session_key = interaction_session_key(interaction, state)

    sessions = ResumeSelection.list_recent_sessions(session_key, limit: 20)

    if is_nil(selector) or selector == "" do
      # List recent sessions
      if sessions == [] do
        respond_ephemeral(interaction, "No recent sessions found.")
      else
        lines =
          sessions
          |> Enum.with_index(1)
          |> Enum.map(fn {session, idx} ->
            ref = ResumeSelection.format_session_ref(session.resume)
            "#{idx}. #{ref}"
          end)

        text = ["**Recent sessions:**", "" | lines] |> Enum.join("\n")
        respond_ephemeral(interaction, text <> "\n\nUse `/resume <number>` to switch.")
      end
    else
      # Try to select a session
      case Integer.parse(String.trim(selector)) do
        {n, _} when n >= 1 and n <= length(sessions) ->
          case Enum.at(sessions, n - 1).resume do
            %ResumeToken{engine: "lemon"} = resume ->
              LemonCore.Store.put(:discord_selected_resume, session_key, resume)

              respond_ephemeral(
                interaction,
                "Switched to session: #{ResumeSelection.format_session_ref(resume)}\nNext message will resume this session."
              )

            %ResumeToken{engine: engine} ->
              respond_ephemeral(interaction, unsupported_resume_message(engine))

            _ ->
              respond_ephemeral(
                interaction,
                "Invalid selector. Use a number (1-#{length(sessions)})."
              )
          end

        _ ->
          case ResumeSelection.extract_explicit_resume_and_strip(selector) do
            {:unsupported, engine} ->
              respond_ephemeral(interaction, unsupported_resume_message(engine))

            _ ->
              case ResumeSelection.resolve_resume_selector(selector, sessions) do
                %ResumeToken{engine: "lemon"} = resume ->
                  LemonCore.Store.put(:discord_selected_resume, session_key, resume)

                  respond_ephemeral(
                    interaction,
                    "Switched to session: #{ResumeSelection.format_session_ref(resume)}"
                  )

                _ ->
                  respond_ephemeral(
                    interaction,
                    "Invalid selector. Use a number (1-#{length(sessions)})."
                  )
              end
          end
      end
    end

    state
  end

  # ============================================================================
  # /cancel Command
  # ============================================================================

  defp handle_cancel_interaction(interaction, state) do
    session_key = interaction_session_key(interaction, state)

    case RouterBridge.active_run(session_key) do
      {:ok, run_id} ->
        case LemonChannels.Runtime.cancel_by_run_id(run_id, :user_requested) do
          :ok ->
            _ = respond_ephemeral(interaction, "Cancelling run...")

          {:error, _} = error ->
            Logger.warning("discord cancel failed: reason=#{SubmissionOutcome.log_label(error)}")

            _ = respond_ephemeral(interaction, cancellation_failure_message(error))
        end

      :none ->
        _ = respond_ephemeral(interaction, "No active run to cancel.")

      {:error, reason} ->
        Logger.warning(
          "discord cancel unavailable: reason=#{SubmissionOutcome.log_label({:error, reason})}"
        )

        _ = respond_ephemeral(interaction, "Cancel not available: the router is unavailable.")
    end

    state
  end

  defp handle_checkpoint_interaction(interaction, state) do
    respond_ephemeral(
      interaction,
      LemonChannels.CheckpointStatusMessage.handle(
        checkpoint_interaction_args(interaction),
        checkpoint_opts(interaction, state)
      )
    )

    state
  end

  defp handle_rollback_interaction(interaction, state) do
    respond_ephemeral(
      interaction,
      LemonChannels.CheckpointStatusMessage.handle_rollback(
        checkpoint_interaction_args(interaction),
        checkpoint_opts(interaction, state)
      )
    )

    state
  end

  defp checkpoint_opts(interaction, state) do
    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction_channel_id(interaction),
      topic_id: interaction_thread_id(interaction)
    }

    session_key = interaction_session_key(interaction, state)

    [
      agent_id: BindingResolver.resolve_agent_id(scope),
      session_key: session_key,
      sender_id: interaction_user_id(interaction),
      checkpoint_owner: LemonChannels.CheckpointStatusMessage.owner_for_session_key(session_key)
    ]
  end

  defp handle_goal_interaction(interaction, state) do
    session_key = interaction_session_key(interaction, state)
    subcommand = session_subcommand(interaction) || "status"

    args =
      case subcommand do
        "set" ->
          objective = nested_option_value(interaction, "set", "objective")
          max_continuations = nested_option_value(interaction, "set", "max_continuations")

          budget_arg =
            if is_integer(max_continuations),
              do: " --max-continuations #{max_continuations}",
              else: ""

          if is_binary(objective), do: "set#{budget_arg} " <> objective, else: "set"

        "clear" ->
          "clear"

        "pause" ->
          "pause"

        "resume" ->
          "resume"

        "continue" ->
          "continue" <> goal_interaction_options(interaction, "continue")

        "loop_once" ->
          "loop once" <> goal_interaction_options(interaction, "loop_once")

        "loop_start" ->
          "loop start" <> goal_interaction_options(interaction, "loop_start")

        "loop_status" ->
          "loop status"

        "loop_stop" ->
          "loop stop"

        _ ->
          "status"
      end

    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction_channel_id(interaction),
      topic_id: interaction_thread_id(interaction)
    }

    # Goal work runs later under this channel's channel-run authority; with no
    # peer kind the router applies the group approval floor. Judge ticks and
    # continuations run off this process and post their result as a follow-up.
    text =
      try do
        LemonChannels.GoalStatusMessage.handle(session_key, args,
          agent_id: BindingResolver.resolve_agent_id(scope),
          workspace: BindingResolver.resolve_cwd(scope),
          channel_context: %{
            channel_id: "discord",
            peer_id: interaction |> interaction_channel_id() |> maybe_to_string()
          },
          meta: %{transport: "discord"},
          start_task: &start_task/1,
          deliver: &send_followup(interaction, &1)
        )
      catch
        :exit, _ -> "Goal command failed: the goal service did not answer in time."
      end

    respond_ephemeral(interaction, text)
    state
  end

  defp handle_kanban_interaction(interaction, state) do
    args = kanban_interaction_args(interaction)

    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction_channel_id(interaction),
      topic_id: interaction_thread_id(interaction)
    }

    channel_id = interaction |> interaction_channel_id() |> maybe_to_string()

    # Discord interactions carry no operator attestation, so kanban changes are
    # refused here; reads stay scoped to this channel's own session principal.
    respond_ephemeral(
      interaction,
      LemonChannels.KanbanStatusMessage.handle(args,
        agent_id: BindingResolver.resolve_agent_id(scope),
        session_key: interaction_session_key(interaction, state),
        workspace: BindingResolver.resolve_cwd(scope),
        operator?: false,
        channel_context: %{channel_id: "discord", peer_id: channel_id},
        meta: %{
          "notificationSessionKey" => interaction_session_key(interaction, state),
          transport: "discord"
        }
      )
    )

    state
  end

  defp handle_media_interaction(interaction, state) do
    args = media_interaction_args(interaction)

    respond_ephemeral(interaction, LemonChannels.MediaStatusMessage.handle(args))

    state
  end

  defp checkpoint_interaction_args(interaction) do
    subcommand = session_subcommand(interaction) || "status"

    case subcommand do
      "events" ->
        "events" <> value_arg(nested_option_value(interaction, "events", "limit"))

      "diff" ->
        "diff" <> value_arg(nested_option_value(interaction, "diff", "checkpoint_id"))

      "restore" ->
        checkpoint_id = nested_option_value(interaction, "restore", "checkpoint_id")
        token = nested_option_value(interaction, "restore", "token")
        "restore" <> value_arg(checkpoint_id) <> value_arg(token)

      _ ->
        "status"
    end
  end

  defp kanban_interaction_args(interaction) do
    subcommand = session_subcommand(interaction) || "boards"

    case subcommand do
      "boards" ->
        "boards" <> kanban_interaction_options(interaction, "boards", [:status, :limit])

      "create" ->
        "create" <> value_arg(nested_option_value(interaction, "create", "name"))

      "show" ->
        board_id = nested_option_value(interaction, "show", "board_id")

        "show" <>
          value_arg(board_id) <> kanban_interaction_options(interaction, "show", [:limit])

      "archive" ->
        "archive" <> value_arg(nested_option_value(interaction, "archive", "board_id"))

      "task_create" ->
        board_id = nested_option_value(interaction, "task_create", "board_id")
        title = nested_option_value(interaction, "task_create", "title")

        "task create" <>
          value_arg(board_id) <>
          kanban_interaction_options(interaction, "task_create", [:priority]) <>
          value_arg(title)

      "task_update" ->
        task_id = nested_option_value(interaction, "task_update", "task_id")

        "task update" <>
          value_arg(task_id) <>
          kanban_interaction_options(interaction, "task_update", [:status, :priority])

      "comment" ->
        task_id = nested_option_value(interaction, "comment", "task_id")
        body = nested_option_value(interaction, "comment", "body")
        "comment" <> value_arg(task_id) <> value_arg(body)

      "dispatch_start" ->
        board_id = nested_option_value(interaction, "dispatch_start", "board_id")

        "dispatch start" <>
          value_arg(board_id) <>
          kanban_interaction_options(interaction, "dispatch_start", [:max_concurrency])

      "dispatch_status" ->
        "dispatch status" <>
          value_arg(nested_option_value(interaction, "dispatch_status", "board_id"))

      "dispatch_stop" ->
        "dispatch stop" <>
          value_arg(nested_option_value(interaction, "dispatch_stop", "board_id"))

      _ ->
        ""
    end
  end

  defp media_interaction_args(interaction) do
    subcommand = session_subcommand(interaction) || "status"
    if subcommand == "status", do: "status", else: ""
  end

  defp kanban_interaction_options(interaction, subcommand, names) do
    names
    |> Enum.map(fn name ->
      option_arg(
        "--#{String.replace(to_string(name), "_", "-")}",
        nested_option_value(interaction, subcommand, to_string(name))
      )
    end)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      args -> " " <> Enum.join(args, " ")
    end
  end

  defp value_arg(nil), do: ""
  defp value_arg(""), do: ""
  defp value_arg(value), do: " #{value}"

  defp goal_interaction_options(interaction, subcommand) do
    [
      option_arg(
        "--max-continuations",
        nested_option_value(interaction, subcommand, "max_continuations")
      ),
      option_arg("--max-ticks", nested_option_value(interaction, subcommand, "max_ticks")),
      auto_arg(nested_option_value(interaction, subcommand, "auto")),
      option_arg("--judge-model", nested_option_value(interaction, subcommand, "judge_model")),
      option_arg(
        "--judge-failure-policy",
        nested_option_value(interaction, subcommand, "judge_failure_policy")
      ),
      option_arg("--model", nested_option_value(interaction, subcommand, "model"))
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      args -> " " <> Enum.join(args, " ")
    end
  end

  defp option_arg(_flag, nil), do: nil
  defp option_arg(_flag, ""), do: nil
  defp option_arg(flag, value), do: "#{flag} #{value}"

  defp auto_arg(true), do: "--auto"
  defp auto_arg(_), do: nil

  # Components map to the catalog command they act for, so they pass the same
  # location gate (and any adminOnly rule) as that slash command.
  defp component_command(custom_id) do
    cond do
      String.starts_with?(custom_id, @cancel_callback_prefix <> ":") -> "stop"
      String.starts_with?(custom_id, @idle_keepalive_continue_prefix) -> "stop"
      String.starts_with?(custom_id, @idle_keepalive_stop_prefix) -> "stop"
      String.starts_with?(custom_id, @model_callback_prefix) -> "model"
      true -> nil
    end
  end

  defp component_allowed?(interaction, custom_id, state) do
    inbound = interaction_to_inbound(interaction, "", state)

    allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) and
      CommandAuthority.authorize(
        component_command(custom_id),
        CommandAuthority.discord_admin?(interaction)
      ) == :ok
  end

  # Run controls act only on the clicker's own session's active run.
  defp with_owned_run(interaction, run_id, state, fun) do
    session_key = interaction_to_inbound(interaction, "", state).meta[:session_key]

    case RouterBridge.active_run(session_key) do
      {:ok, ^run_id} ->
        fun.()

      {:error, _} ->
        respond_ephemeral(interaction, "Run controls are unavailable right now; nothing changed.")

      _ ->
        respond_ephemeral(
          interaction,
          "Only the user who started this run can control it; nothing changed."
        )
    end

    state
  end

  defp handle_cancel_component(interaction, run_id) do
    case LemonChannels.Runtime.cancel_by_run_id(run_id, :user_requested) do
      :ok ->
        update_interaction(interaction, "Cancelling...", [])

      {:error, _} = error ->
        Logger.warning(
          "discord cancel component failed: reason=#{SubmissionOutcome.log_label(error)}"
        )

        # An ephemeral response acknowledges the click without replacing the
        # source message, so its cancel/retry controls remain available.
        respond_ephemeral(interaction, cancellation_failure_message(error))
    end
  end

  defp handle_keepalive_component(interaction, run_id, decision) do
    case LemonChannels.Runtime.keep_run_alive(run_id, decision) do
      :ok when decision == :continue ->
        update_interaction(interaction, "Continuing run.", [])

      :ok ->
        update_interaction(interaction, "Stopping run.", [])

      {:error, _} = error ->
        Logger.warning(
          "discord keep-alive component failed: reason=#{SubmissionOutcome.log_label(error)}"
        )

        # Do not update the source message on failure. Its controls are the
        # user's safe retry path.
        respond_ephemeral(interaction, keepalive_failure_message(error, decision))
    end
  end

  defp cancellation_failure_message(error) do
    if SubmissionOutcome.uncertain?(error) do
      "I couldn't confirm whether cancellation was accepted. Check the run status before trying again."
    else
      "I couldn't cancel the run. Please try again."
    end
  end

  defp keepalive_failure_message(error, decision) do
    action = if decision == :cancel, do: "stopping the run", else: "continuing the run"

    if SubmissionOutcome.uncertain?(error) do
      "I couldn't confirm whether #{action} was accepted. Check the run status before trying again."
    else
      "I couldn't apply that decision. The controls remain available; please try again."
    end
  end

  # ============================================================================
  # /trigger Command
  # ============================================================================

  defp handle_trigger_interaction(interaction, state) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    account_id = state.account_id || "default"
    mode_arg = option_value(interaction, "mode") || "status"
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

    case mode_arg do
      "status" ->
        current = TriggerMode.resolve(account_id, channel_id, thread_id)
        respond_ephemeral(interaction, render_trigger_status(current))

      mode when mode in ~w(mentions all) ->
        :ok = TriggerMode.set(scope, account_id, String.to_existing_atom(mode))
        respond_ephemeral(interaction, render_trigger_set(mode, scope))

      "clear" ->
        if is_integer(thread_id) do
          :ok = TriggerMode.clear_topic(account_id, channel_id, thread_id)
          respond_ephemeral(interaction, "Cleared thread trigger override.")
        else
          respond_ephemeral(interaction, "No thread override to clear.")
        end

      _ ->
        respond_ephemeral(interaction, "Usage: /trigger [mentions|all|clear|status]")
    end

    state
  end

  # ============================================================================
  # /cwd Command
  # ============================================================================

  defp handle_cwd_interaction(interaction, state) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    path_arg = option_value(interaction, "path")
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

    cond do
      is_nil(path_arg) or path_arg == "" ->
        respond_ephemeral(interaction, render_cwd_status(scope))

      String.downcase(path_arg) == "clear" ->
        had? = scope_has_cwd_override?(scope)
        clear_cwd_override(scope)
        respond_ephemeral(interaction, render_cwd_cleared(scope, had?))

      true ->
        case maybe_select_project_for_scope(scope, path_arg) do
          {:ok, %{root: root}} ->
            respond_ephemeral(interaction, render_cwd_set(scope, root))

          {:error, msg} ->
            respond_ephemeral(interaction, msg)

          _ ->
            respond_ephemeral(interaction, "Usage: /cwd [project_id|path|clear]")
        end
    end

    state
  end

  # ============================================================================
  # /file Command
  # ============================================================================

  defp handle_file_interaction(interaction, state) do
    sub = file_subcommand(interaction)

    case sub do
      "put" ->
        handle_file_put_interaction(interaction, state)

      "get" ->
        handle_file_get_interaction(interaction, state)

      _ ->
        respond_ephemeral(interaction, "Usage: /file put <attachment> [path] or /file get <path>")
    end

    state
  end

  defp handle_file_put_interaction(interaction, state) do
    attachment = FileOperations.extract_resolved_attachment(interaction, "put", "attachment")
    dest_path = nested_option_value(interaction, "put", "path")
    force = nested_option_value(interaction, "put", "force") == true

    if is_nil(attachment) do
      respond_ephemeral(interaction, "Please attach a file to upload.")
    else
      run_file_transfer(interaction, fn ->
        FileOperations.handle_file_put(state, interaction, attachment, dest_path, force)
      end)
    end
  end

  defp handle_file_get_interaction(interaction, state) do
    file_path = nested_option_value(interaction, "get", "path")

    if is_nil(file_path) or file_path == "" do
      respond_ephemeral(interaction, "Please specify a file path.")
    else
      run_file_transfer(interaction, fn ->
        FileOperations.handle_file_get(state, interaction, file_path)
      end)
    end
  end

  # Downloads, archives and uploads can take minutes; they run beside the
  # serial event queue so other chats and interactions keep moving.
  defp run_file_transfer(interaction, transfer) do
    case start_task(fn ->
           {_status, msg} = transfer.()
           respond_ephemeral(interaction, msg)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, _reason} ->
        respond_ephemeral(interaction, "Lemon is busy right now. Try the file transfer again.")
    end
  end

  defp file_subcommand(interaction) do
    interaction
    |> map_get(:data)
    |> map_get(:options)
    |> List.wrap()
    |> List.first()
    |> map_get(:name)
  end

  # ============================================================================
  # /topic Command — Thread & Forum Post Creation
  # ============================================================================

  defp handle_topic_interaction(interaction, state) do
    topic_name = option_value(interaction, "name")
    initial_msg = option_value(interaction, "message") || "Thread started."
    channel_id = interaction |> map_get(:channel_id) |> parse_id()

    if not is_binary(topic_name) or String.trim(topic_name) == "" do
      respond_ephemeral(interaction, "Thread name cannot be empty.")
      state
    else
      respond_ephemeral(interaction, "Creating thread...")

      # Thread creation is platform I/O: run it beside the serial event queue.
      _ =
        start_task(fn ->
          # Try forum post first, fall back to regular thread
          case create_thread_or_forum_post(channel_id, topic_name, initial_msg) do
            {:ok, thread} ->
              thread_id = map_get(thread, :id)
              send_followup(interaction, "Created: <##{thread_id}>")

            {:error, reason} ->
              Logger.warning("Discord thread creation failed: #{inspect(reason)}")

              send_followup(
                interaction,
                "Failed to create thread. Check that the bot can create threads in this channel, then try again."
              )
          end
        end)

      state
    end
  end

  defp create_thread_or_forum_post(channel_id, name, initial_message)
       when is_integer(channel_id) do
    # First try as a forum channel (create_in_forum)
    case Thread.create_in_forum(channel_id, %{
           name: name,
           message: %{content: initial_message},
           auto_archive_duration: 10_080
         }) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, _} ->
        # Fall back to regular thread creation
        Thread.create(channel_id, %{
          name: name,
          type: 11,
          auto_archive_duration: 10_080
        })
    end
  rescue
    _ -> {:error, :thread_creation_failed}
  end

  # ============================================================================
  # Thread Create Event — Auto-join Forum Threads
  # ============================================================================

  defp maybe_handle_thread_create(thread, state) do
    # Auto-join forum threads in allowed guilds so we can receive messages
    thread_id = map_get(thread, :id) |> parse_id()
    guild_id = map_get(thread, :guild_id) |> parse_id()

    # Check if this is in an allowed guild
    guild_allowed? =
      case state.allowed_guild_ids do
        nil -> true
        set -> is_integer(guild_id) and MapSet.member?(set, guild_id)
      end

    if guild_allowed? and is_integer(thread_id) do
      # Auto-join the thread so we receive MESSAGE_CREATE events in it
      start_task(fn ->
        _ = Thread.join(thread_id)
      end)
    end

    state
  end

  # ============================================================================
  # Trigger Mode
  # ============================================================================

  defp should_ignore_for_trigger?(state, inbound, _text) do
    case inbound.peer.kind do
      :group ->
        channel_id = inbound.meta[:channel_id]
        thread_id = inbound.meta[:thread_id]
        account_id = state.account_id || "default"

        if is_integer(channel_id) do
          trigger = TriggerMode.resolve(account_id, channel_id, thread_id)
          trigger.mode == :mentions and not explicit_mention?(state, inbound)
        else
          false
        end

      _ ->
        false
    end
  end

  defp explicit_mention?(state, inbound) do
    text = inbound.message.text || ""
    bot_id = state.bot_user_id

    # Check for @mention of bot in message content
    mention_pattern = if is_integer(bot_id), do: "<@#{bot_id}>", else: nil

    cond do
      is_binary(mention_pattern) and String.contains?(text, mention_pattern) -> true
      # Check if replying to bot
      reply_to_bot?(inbound, state) -> true
      true -> false
    end
  end

  defp reply_to_bot?(%{meta: %{reply_to_author_id: author_id}}, %{bot_user_id: bot_id})
       when is_integer(author_id) and is_integer(bot_id),
       do: author_id == bot_id

  defp reply_to_bot?(_inbound, _state), do: false

  # ============================================================================
  # Rendering Helpers
  # ============================================================================

  defp render_model_picker_text(session_model, future_model) do
    session_line = if is_binary(session_model), do: session_model, else: "(not set)"
    future_line = if is_binary(future_model), do: future_model, else: "(not set)"

    [
      "**Model Picker**",
      "",
      "Session model: #{session_line}",
      "Future default: #{future_line}",
      "",
      "Choose a provider:"
    ]
    |> Enum.join("\n")
  end

  defp render_thinking_status(state, %ChatScope{} = scope) do
    account_id = state.account_id || "default"

    topic_level =
      if is_integer(scope.topic_id),
        do:
          ModelPolicyAdapter.default_thinking_preference(
            account_id,
            scope.chat_id,
            scope.topic_id
          ),
        else: nil

    chat_level = ModelPolicyAdapter.default_thinking_preference(account_id, scope.chat_id, nil)

    {effective_level, source} =
      cond do
        is_binary(topic_level) and topic_level != "" -> {topic_level, :topic}
        is_binary(chat_level) and chat_level != "" -> {chat_level, :chat}
        true -> {nil, nil}
      end

    scope_label = thinking_scope_label(scope)

    [
      "Thinking level for #{scope_label}: #{ModelPolicyAdapter.format_thinking_line(effective_level, source)}",
      "Channel default: #{chat_level || "none"}",
      "Thread override: #{topic_level || "none"}",
      thinking_usage()
    ]
    |> Enum.join("\n")
  end

  defp render_thinking_set(%ChatScope{topic_id: topic_id}, level) when is_integer(topic_id) do
    "Thinking level set to **#{level}** for this thread.\n#{thinking_usage()}"
  end

  defp render_thinking_set(%ChatScope{}, level) do
    "Thinking level set to **#{level}** for this channel.\n#{thinking_usage()}"
  end

  defp render_thinking_cleared(%ChatScope{topic_id: topic_id}, had?) when is_integer(topic_id) do
    if had?,
      do: "Cleared thinking level override for this thread.",
      else: "No override was set for this thread."
  end

  defp render_thinking_cleared(%ChatScope{}, had?) do
    if had?,
      do: "Cleared thinking level override for this channel.",
      else: "No override was set for this channel."
  end

  defp thinking_scope_label(%ChatScope{topic_id: topic_id}) when is_integer(topic_id),
    do: "this thread"

  defp thinking_scope_label(_), do: "this channel"

  defp thinking_usage,
    do: "Usage: `/thinking [off|minimal|low|medium|high|xhigh|auto|clear|status]`"

  defp normalize_thinking_arg(arg) when is_binary(arg) do
    case String.downcase(String.trim(arg)) do
      "" -> :status
      "status" -> :status
      "clear" -> :clear
      level when level in @thinking_levels -> {:set, level}
      _ -> :invalid
    end
  end

  defp normalize_thinking_arg(_), do: :invalid

  defp render_trigger_status(%{mode: mode, chat_mode: chat_mode, topic_mode: topic_mode}) do
    base =
      if mode == :mentions, do: "Trigger mode: **mentions-only**", else: "Trigger mode: **all**"

    chat_line = "Channel default: #{chat_mode || "not set"}"
    topic_line = "Thread override: #{topic_mode || "none"}"
    [base, chat_line, topic_line, "Use `/trigger [mentions|all|clear]`"] |> Enum.join("\n")
  end

  defp render_trigger_set(mode, %ChatScope{topic_id: nil}),
    do: "Trigger mode set to **#{mode}** for this channel."

  defp render_trigger_set(mode, _), do: "Trigger mode set to **#{mode}** for this thread."

  defp render_cwd_status(%ChatScope{} = scope) do
    cwd = BindingResolver.resolve_cwd(scope)
    scope_label = cwd_scope_label(scope)

    if is_binary(cwd) and cwd != "" do
      "Working directory for #{scope_label}: `#{Path.expand(cwd)}`\nUsage: `/cwd [project_id|path|clear]`"
    else
      "No working directory configured for #{scope_label}.\nUsage: `/cwd [project_id|path|clear]`"
    end
  end

  defp render_cwd_set(scope, root) do
    "Working directory set for #{cwd_scope_label(scope)}: `#{Path.expand(root)}`"
  end

  defp render_cwd_cleared(scope, had?) do
    if had?,
      do: "Cleared working directory override for #{cwd_scope_label(scope)}.",
      else: "No /cwd override was set for #{cwd_scope_label(scope)}."
  end

  defp cwd_scope_label(%ChatScope{topic_id: topic_id}) when is_integer(topic_id),
    do: "this thread"

  defp cwd_scope_label(_), do: "this channel"

  defp resolve_cwd_display(scope) do
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

  defp format_model_line(model_value, model_scope)
       when is_binary(model_value) and model_value != "" do
    case model_scope do
      :session -> "#{model_value} (session override)"
      :future -> "#{model_value} (channel default)"
      _ -> model_value
    end
  end

  defp format_model_line(_, _) do
    cfg = LemonCore.Config.cached()
    agent = map_get(cfg, :agent) || %{}
    default = map_get(agent, :default_model) || "claude-sonnet-4-20250514"
    "#{default} (default)"
  end

  defp started_new_session_message(state, %ChatScope{} = scope, session_key, project, base_msg) do
    {model_hint, model_scope} =
      resolve_model_hint(state, session_key, scope.chat_id, scope.topic_id)

    model_line = format_model_line(model_hint, model_scope)
    {thinking_hint, thinking_scope} = resolve_thinking_hint(state, scope.chat_id, scope.topic_id)
    thinking_line = ModelPolicyAdapter.format_thinking_line(thinking_hint, thinking_scope)
    cwd_line = resolve_cwd_display(scope)

    lines = [
      base_msg,
      "Model: #{model_line}",
      "Thinking: #{thinking_line}",
      "CWD: #{cwd_line}",
      "Account: #{state.account_id || "default"}",
      "Session: `#{session_key || "(unavailable)"}`"
    ]

    lines =
      case project do
        %{id: id, root: root} -> lines ++ ["Project: #{id} (#{root})"]
        _ -> lines
      end

    Enum.join(lines, "\n")
  end

  # ============================================================================
  # CWD / Project Helpers
  # ============================================================================

  defp maybe_select_project_for_scope(%ChatScope{} = scope, selector) when is_binary(selector),
    do: LemonChannels.ProjectSelection.select(scope, selector)

  defp scope_has_cwd_override?(%ChatScope{} = scope) do
    case BindingResolver.get_project_override(scope) do
      override when is_binary(override) and override != "" -> true
      _ -> false
    end
  end

  defp clear_cwd_override(%ChatScope{} = scope) do
    _ = ProjectBindingStore.delete_override(scope)
    :ok
  end

  defp extract_project_info({:ok, %{id: id, root: root}}), do: %{id: id, root: root}
  defp extract_project_info(_), do: nil

  # ============================================================================
  # Discord API Helpers
  # ============================================================================

  defp respond_ephemeral(interaction, content) do
    payload = %{
      type: 4,
      data: %{content: content, flags: 64, allowed_mentions: safe_allowed_mentions()}
    }

    safe_interaction_response(interaction, payload)
  end

  defp respond_with_components(interaction, content, components, opts) do
    flags = if Keyword.get(opts, :ephemeral, false), do: 64, else: 0

    payload = %{
      type: 4,
      data: %{
        content: content,
        components: components,
        flags: flags,
        allowed_mentions: safe_allowed_mentions()
      }
    }

    safe_interaction_response(interaction, payload)
  end

  defp update_interaction(interaction, content, components) do
    payload = %{
      type: 7,
      data: %{content: content, components: components, allowed_mentions: safe_allowed_mentions()}
    }

    safe_interaction_response(interaction, payload)
  end

  defp acknowledge_interaction(interaction) do
    safe_interaction_response(interaction, %{type: 6})
  end

  defp safe_interaction_response(interaction, payload) do
    case Map.get(interaction, :lemon_deferred) do
      %{} = deferred -> deliver_deferred(interaction, deferred, payload)
      nil -> interaction_call(interaction, payload)
    end
  rescue
    error ->
      Logger.warning("discord interaction response failed: #{inspect(error.__struct__)}")
      {:error, {:discord_interaction_crashed, error.__struct__}}
  end

  # The interaction was acknowledged on arrival (type 5 for commands, type 6
  # for components), so replies become edits of the original response or
  # follow-up messages. The first ephemeral command reply fills the deferred
  # "thinking" message; a public one is posted as a follow-up and the
  # placeholder removed.
  defp deliver_deferred(_interaction, _deferred, %{type: 6}), do: {:ok}

  defp deliver_deferred(interaction, _deferred, %{type: 7, data: data}),
    do: interaction_call(interaction, %{type: :edit_original, data: data})

  defp deliver_deferred(interaction, %{kind: :component}, %{type: 4, data: data}),
    do: interaction_call(interaction, %{type: :followup, data: data})

  defp deliver_deferred(interaction, %{kind: :command, claim: claim}, %{type: 4, data: data}) do
    first? = :atomics.compare_exchange(claim, 1, 0, 1) == :ok
    ephemeral? = Bitwise.band(Map.get(data, :flags, 0) || 0, 64) != 0

    cond do
      first? and ephemeral? ->
        interaction_call(interaction, %{type: :edit_original, data: Map.delete(data, :flags)})

      first? ->
        result = interaction_call(interaction, %{type: :followup, data: data})
        _ = interaction_call(interaction, %{type: :delete_original})
        result

      true ->
        interaction_call(interaction, %{type: :followup, data: data})
    end
  end

  defp deliver_deferred(interaction, _deferred, payload),
    do: interaction_call(interaction, payload)

  defp interaction_call(interaction, payload) do
    interaction =
      interaction |> ThreadResolver.without_location() |> Map.delete(:lemon_deferred)

    app_id = map_get(interaction, :application_id)
    token = map_get(interaction, :token)

    case {Application.get_env(:lemon_channels, :discord_interaction_responder), payload} do
      {responder, _} when is_function(responder, 2) ->
        responder.(interaction, payload)

      {{mod, fun}, _} when is_atom(mod) and is_atom(fun) ->
        apply(mod, fun, [interaction, payload])

      {_, %{type: :edit_original, data: data}} ->
        Interaction.edit_response(app_id, token, data)

      {_, %{type: :followup, data: data}} ->
        Interaction.create_followup_message(app_id, token, data)

      {_, %{type: :delete_original}} ->
        Interaction.delete_response(app_id, token)

      _ ->
        Interaction.create_response(interaction, payload)
    end
  end

  defp send_followup(interaction, content) do
    token = map_get(interaction, :token)
    app_id = map_get(interaction, :application_id)

    if is_binary(token) and app_id do
      Webhook.execute(app_id, token, %{
        content: content,
        flags: 64,
        allowed_mentions: safe_allowed_mentions()
      })
    end
  rescue
    error -> {:error, {:discord_followup_crashed, error}}
  end

  defp send_channel_message(channel_id, text) when is_integer(channel_id) and is_binary(text) do
    Message.create(channel_id, %{
      content: text,
      allowed_mentions: safe_allowed_mentions()
    })
  rescue
    error -> {:error, {:discord_send_crashed, error}}
  end

  defp safe_allowed_mentions, do: %{parse: [], replied_user: false}

  # ============================================================================
  # Session & Routing Helpers
  # ============================================================================

  defp interaction_to_inbound(interaction, prompt, state) do
    channel_id = interaction_channel_id(interaction)
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    interaction_id = interaction |> map_get(:id) |> parse_id()
    user_id = interaction_user_id(interaction)
    thread_id = interaction_thread_id(interaction)

    peer_kind = if is_integer(guild_id), do: :group, else: :dm

    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    agent_id = BindingResolver.resolve_agent_id(scope)
    account_id = Map.get(state, :account_id, "default")

    session_key =
      session_key_for(
        agent_id,
        account_id,
        peer_kind,
        channel_id,
        user_id,
        thread_id,
        guild_id
      )

    %InboundMessage{
      channel_id: "discord",
      account_id: account_id,
      peer: %{
        kind: peer_kind,
        id: Integer.to_string(channel_id),
        thread_id: maybe_to_string(thread_id)
      },
      sender: %{
        id: maybe_to_string(user_id),
        username: nil,
        display_name: nil
      },
      message: %{
        id: maybe_to_string(interaction_id),
        text: prompt,
        timestamp: System.system_time(:second),
        reply_to_id: nil
      },
      raw: interaction,
      meta: %{
        session_key: session_key,
        agent_id: agent_id,
        user_msg_id: nil,
        channel_id: channel_id,
        guild_id: guild_id,
        thread_id: thread_id,
        user_id: user_id,
        source: :slash
      }
    }
  end

  defp normalize_message_inbound(message, state) do
    with {:ok, inbound} <- Inbound.normalize(%{message: message, account_id: state.account_id}) do
      channel_id = inbound.meta[:channel_id]
      guild_id = inbound.meta[:guild_id]
      thread_id = inbound.meta[:thread_id]
      user_id = inbound.meta[:user_id] |> parse_id()
      peer_kind = inbound.peer.kind

      scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
      agent_id = BindingResolver.resolve_agent_id(scope)

      session_key =
        session_key_for(
          agent_id,
          state.account_id,
          peer_kind,
          channel_id,
          user_id,
          thread_id,
          guild_id
        )

      meta =
        inbound.meta
        |> Map.put(:session_key, session_key)
        |> Map.put(:agent_id, agent_id)

      {:ok, %{inbound | meta: meta}}
    end
  end

  defp build_session_key(state, inbound, scope) do
    channel_id = inbound.meta[:channel_id]
    guild_id = inbound.meta[:guild_id]
    thread_id = inbound.meta[:thread_id]
    user_id = inbound.meta[:user_id] |> parse_id()
    peer_kind = inbound.peer.kind
    agent_id = if scope, do: BindingResolver.resolve_agent_id(scope), else: "default"

    session_key_for(
      agent_id,
      state.account_id,
      peer_kind,
      channel_id,
      user_id,
      thread_id,
      guild_id
    )
  end

  defp session_key_for(agent_id, account_id, peer_kind, channel_id, user_id, thread_id, guild_id) do
    opts = %{
      agent_id: agent_id || "default",
      channel_id: "discord",
      account_id: account_id || "default",
      peer_kind: peer_kind,
      peer_id: Integer.to_string(channel_id),
      thread_id: maybe_to_string(thread_id)
    }

    opts =
      if is_integer(guild_id) and is_integer(user_id),
        do: Map.put(opts, :sub_id, Integer.to_string(user_id)),
        else: opts

    SessionKey.channel_peer(opts)
  end

  defp interaction_session_key(interaction, state) do
    channel_id = interaction_channel_id(interaction)
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    user_id = interaction_user_id(interaction)
    thread_id = interaction_thread_id(interaction)

    peer_kind = if is_integer(guild_id), do: :group, else: :dm
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    agent_id = BindingResolver.resolve_agent_id(scope)

    session_key_for(
      agent_id,
      state.account_id,
      peer_kind,
      channel_id,
      user_id,
      thread_id,
      guild_id
    )
  end

  defp interaction_user_id(interaction) do
    member_user_id =
      interaction |> map_get(:member) |> map_get(:user) |> map_get(:id) |> parse_id()

    member_user_id || interaction |> map_get(:user) |> map_get(:id) |> parse_id()
  end

  # Every interaction passes through ThreadResolver.put_location/1 on entry,
  # so these read the same {parent channel, thread} pair messages use.
  defp interaction_channel_id(interaction), do: ThreadResolver.location!(interaction).channel_id
  defp interaction_thread_id(interaction), do: ThreadResolver.location!(interaction).thread_id

  defp resolve_model_hint(state, session_key, channel_id, thread_id) do
    ModelPolicyAdapter.resolve_model_hint(
      state.account_id || "default",
      session_key,
      channel_id,
      thread_id
    )
  end

  defp resolve_thinking_hint(state, channel_id, thread_id) do
    ModelPolicyAdapter.resolve_thinking_hint(state.account_id || "default", channel_id, thread_id)
  end

  defp route_to_router(state, %InboundMessage{} = inbound) do
    meta = inbound.meta || %{}
    channel_id = meta[:channel_id]
    thread_id = meta[:thread_id]

    typing = [
      target: {:discord, state.account_id, thread_id || channel_id},
      session_key: meta[:session_key],
      interval_ms: 8_000,
      send: fn -> Outbound.start_typing(thread_id || channel_id) end
    ]

    case LemonChannels.Runtime.submit_inbound(inbound, typing: typing) do
      :ok ->
        :ok

      {:error, _} = error ->
        Logger.warning(
          "discord inbound routing failed: reason=#{SubmissionOutcome.log_label(error)}"
        )

        error
    end
  end

  defp safe_delete_chat_state(key) do
    ChatStateStore.delete(key)
  end

  defp maybe_subscribe_to_session(session_key) when is_binary(session_key) do
    topic = LemonCore.Bus.session_topic(session_key)
    _ = subscription(:subscribe, topic)
  end

  defp maybe_subscribe_exec_approvals do
    _ = LemonCore.Bus.subscribe("exec_approvals")

    :ok
  end

  defp run_completed_ok?(event) do
    case event.payload do
      %{completed: %{ok: ok}} when is_boolean(ok) -> ok
      %{ok: ok} when is_boolean(ok) -> ok
      _ -> true
    end
  end

  defp maybe_index_known_target(state, %InboundMessage{} = inbound) do
    account_id = state.account_id || inbound.account_id || "default"
    channel_id = inbound.meta[:channel_id] |> parse_id()
    thread_id = inbound.meta[:thread_id] |> parse_id()

    with true <- is_binary(account_id) and account_id != "",
         true <- is_integer(channel_id) do
      key = {account_id, channel_id, thread_id}
      existing = KnownTargetStore.get(key) || %{}
      now = System.system_time(:millisecond)

      entry =
        %{
          channel_id: "discord",
          account_id: account_id,
          peer_kind: inbound.peer.kind |> to_string(),
          peer_id: Integer.to_string(channel_id),
          thread_id: maybe_to_string(thread_id),
          discord_channel_id: channel_id,
          discord_thread_id: thread_id,
          guild_id: inbound.meta[:guild_id] |> parse_id(),
          channel_name: coalesce_text(ThreadResolver.name(channel_id), existing, :channel_name),
          thread_name: coalesce_text(ThreadResolver.name(thread_id), existing, :thread_name),
          updated_at_ms: now,
          first_seen_at_ms: field(existing, :first_seen_at_ms) || now
        }
        |> maybe_put(:last_message_id, inbound.meta[:user_msg_id] |> parse_id())

      if should_persist_known_target?(existing, entry, now) do
        _ = KnownTargetStore.put(key, entry)
      end
    end

    :ok
  end

  defp coalesce_text(value, _existing, _key) when is_binary(value) and value != "", do: value
  defp coalesce_text(_value, existing, key), do: field(existing, key)

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil

  defp should_persist_known_target?(existing, entry, now) do
    field_changed?(existing, entry, :channel_name) or
      field_changed?(existing, entry, :thread_name) or
      field_changed?(existing, entry, :peer_kind) or
      now - (field(existing, :updated_at_ms) || 0) >= @known_target_refresh_ms
  end

  defp field_changed?(existing, entry, key), do: field(existing, key) != Map.get(entry, key)

  # ============================================================================
  # Access Checks
  # ============================================================================

  defp not_self_message?(message, state) do
    author = map_get(message, :author)
    author_id = map_get(author, :id) |> parse_id()
    webhook? = not is_nil(map_get(message, :webhook_id))

    author_id != state.bot_user_id and not webhook?
  end

  defp allowed_inbound?(%InboundMessage{} = inbound, state) do
    guild_id = inbound.meta[:guild_id] |> parse_id()
    channel_id = inbound.meta[:channel_id] |> parse_id()

    guild_allowed? =
      case Map.get(state, :allowed_guild_ids) do
        nil -> true
        set -> is_integer(guild_id) and MapSet.member?(set, guild_id)
      end

    channel_allowed? =
      case Map.get(state, :allowed_channel_ids) do
        nil -> true
        set -> is_integer(channel_id) and MapSet.member?(set, channel_id)
      end

    if inbound.peer.kind == :dm and Map.get(state, :unauthorized_dm_behavior, "ignore") == "pair" do
      is_struct(Map.get(state, :allowed_channel_ids), MapSet) and
        MapSet.member?(state.allowed_channel_ids, channel_id)
    else
      guild_allowed? and channel_allowed?
    end
  end

  defp binding_allowed?(%InboundMessage{} = inbound, state) do
    if Map.get(state, :deny_unbound_channels, false) == true and inbound.peer.kind != :dm do
      scope = %ChatScope{
        transport: :discord,
        chat_id: inbound.meta[:channel_id],
        topic_id: inbound.meta[:thread_id]
      }

      not is_nil(BindingResolver.resolve_binding(scope))
    else
      true
    end
  rescue
    _ -> false
  end

  # ============================================================================
  # Slash Command Registration
  # ============================================================================

  defp register_slash_commands do
    for cmd <- slash_commands() do
      _ =
        try do
          ApplicationCommand.create_global_command(cmd)
        rescue
          _ -> :ok
        end
    end

    :ok
  end

  # ============================================================================
  # Option & Value Extraction
  # ============================================================================

  defp option_value(interaction, option_name) do
    options =
      interaction
      |> map_get(:data)
      |> map_get(:options)

    options
    |> List.wrap()
    |> Enum.find_value(fn option ->
      if map_get(option, :name) == option_name, do: map_get(option, :value), else: nil
    end)
    |> normalize_blank()
  end

  defp nested_option_value(interaction, subcommand, option_name) do
    options =
      interaction
      |> map_get(:data)
      |> map_get(:options)
      |> List.wrap()

    sub_options =
      Enum.find_value(options, [], fn option ->
        if map_get(option, :name) == subcommand, do: map_get(option, :options) || [], else: nil
      end)

    sub_options
    |> List.wrap()
    |> Enum.find_value(fn option ->
      if map_get(option, :name) == option_name, do: map_get(option, :value), else: nil
    end)
    |> normalize_blank()
  end

  defp session_subcommand(interaction) do
    interaction
    |> map_get(:data)
    |> map_get(:options)
    |> List.wrap()
    |> List.first()
    |> map_get(:name)
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  # An absent list leaves channels unrestricted, but a configured list is a
  # closed set even when empty: revoking the last channel must stay deny-all
  # across restarts instead of reopening every channel.
  @doc false
  def parse_allowed_channel_ids(value) when is_list(value),
    do: value |> Enum.map(&parse_id/1) |> Enum.filter(&is_integer/1) |> MapSet.new()

  def parse_allowed_channel_ids(_), do: nil

  defp parse_allowed_ids(value) when is_list(value) do
    ids = value |> Enum.map(&parse_id/1) |> Enum.filter(&is_integer/1)
    if ids == [], do: nil, else: MapSet.new(ids)
  end

  defp parse_allowed_ids(_), do: nil

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> nil
    end
  end

  defp parse_id(_), do: nil

  defp merge_config(base, nil), do: base
  defp merge_config(base, cfg) when is_map(cfg), do: Map.merge(base || %{}, cfg)

  defp merge_config(base, cfg) when is_list(cfg) do
    if Keyword.keyword?(cfg), do: Map.merge(base || %{}, Enum.into(cfg, %{})), else: base || %{}
  end

  defp cfg_get(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(value) when is_integer(value) or is_boolean(value), do: value
  defp normalize_blank(_), do: nil

  defp maybe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp maybe_to_string(value) when is_binary(value), do: value
  defp maybe_to_string(_), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ============================================================================
  # Nostrum Consumer
  # ============================================================================

  defmodule Consumer do
    @moduledoc false
    use Nostrum.Consumer

    @transport LemonChannels.Adapters.Discord.Transport

    # Nostrum 0.10's default consumer callback creates an unowned task. Forward
    # directly instead; the transport's task supervisor owns all event work.
    @impl GenServer
    def handle_info({:event, event}, state) do
      handle_event(event)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}

    def handle_event({name, payload, _ws_state} = event) do
      if name in [:READY, :RESUMED] do
        LemonChannels.Registry.record_status("discord", :connected)
      end

      :ok = LemonChannels.Adapters.Discord.ThreadResolver.observe_event(name, payload)

      if pid = Process.whereis(@transport) do
        send(pid, {:discord_event, event})
      end
    end
  end
end

defmodule LemonChannels.Adapters.Discord.Transport do
  @moduledoc """
  Discord transport that routes inbound events to LemonRouter through RouterBridge.
  Feature-complete with model picker, thinking, resume, cancel, trigger, cwd, and reactions.
  """

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Discord.{
    FileOperations,
    Inbound,
    ModelCatalog,
    ModelPicker,
    ModelPolicyAdapter,
    Outbound,
    SlashCommands,
    StatusRenderer,
    TriggerMode
  }

  alias LemonChannels.Adapters.Telegram.Transport.MemoryReflection
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonChannels.BindingResolver
  alias LemonChannels.Cwd
  alias LemonChannels.Discord.KnownTargetStore
  alias LemonChannels.Telegram.TransportShared
  alias LemonCore.ChatScope

  alias LemonCore.{
    ChatStateStore,
    Event,
    Events,
    InboundMessage,
    ProjectBindingStore,
    ResumeToken,
    RouterBridge,
    Secrets,
    SessionKey,
    Store
  }

  alias Nostrum.Api.{ApplicationCommand, Interaction}

  @cancel_callback_prefix "lemon:cancel"
  @model_callback_prefix "lemon:model"
  @idle_keepalive_continue_prefix "lemon:idle:c:"
  @idle_keepalive_stop_prefix "lemon:idle:k:"

  @thinking_levels ~w(off minimal low medium high xhigh)
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
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}

    config =
      base
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    token = cfg_get(config, :bot_token) || resolve_bot_token_secret(config) || resolve_token()

    if is_binary(token) and String.trim(token) != "" do
      case ensure_nostrum_started(token) do
        :ok ->
          consumer_pid = start_consumer()

          maybe_subscribe_exec_approvals()

          # Initialize dedup table (same pattern as Telegram transport)
          :ok = LemonCore.Dedupe.Ets.init(@dedupe_table)
          _ = :ets.delete_all_objects(@dedupe_table)

          {:ok,
           %{
             consumer_pid: consumer_pid,
             account_id: cfg_get(config, :account_id, "default"),
             allowed_guild_ids: parse_allowed_ids(cfg_get(config, :allowed_guild_ids)),
             allowed_channel_ids: parse_allowed_ids(cfg_get(config, :allowed_channel_ids)),
             deny_unbound_channels: cfg_get(config, :deny_unbound_channels, false),
             bot_user_id: nil,
             # Model picker state: {channel_id, thread_id, user_id} => picker
             model_pickers: %{},
             # Message debouncing: scope_key => buffer
             buffers: %{},
             # Reaction tracking: session_key => %{channel_id, message_id, user_id}
             reaction_runs: %{},
             # Pending /new: run_id => info
             pending_new: %{},
             debounce_ms: cfg_get(config, :debounce_ms, @debounce_ms),
             dedupe_ttl_ms: cfg_get(config, :dedupe_ttl_ms, @default_dedupe_ttl),
             # File operations config from [gateway.discord.files]
             files: cfg_get(config, :files, %{})
           }}

        {:error, reason} ->
          Logger.warning("discord adapter disabled: #{inspect(reason)}")
          :ignore
      end
    else
      :ignore
    end
  end

  # ============================================================================
  # GenServer Handlers
  # ============================================================================

  @impl true
  def handle_info({:discord_event, {:READY, payload, _ws_state}}, state) do
    _ = register_slash_commands()

    bot_user_id =
      payload
      |> map_get(:user)
      |> map_get(:id)
      |> parse_id()

    {:noreply, %{state | bot_user_id: bot_user_id}}
  end

  def handle_info({:discord_event, {:MESSAGE_CREATE, message, _ws_state}}, state) do
    state = maybe_handle_message(message, state)
    {:noreply, state}
  end

  def handle_info({:discord_event, {:INTERACTION_CREATE, interaction, _ws_state}}, state) do
    state = maybe_handle_interaction(interaction, state)
    {:noreply, state}
  end

  # Debounce flush for buffered messages
  def handle_info({:debounce_flush, scope_key, debounce_ref}, state) do
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
  def handle_info(%LemonCore.Event{type: :run_completed, meta: meta} = event, state) do
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
          _ = send_channel_message(channel_id, msg)

          topic = LemonCore.Bus.run_topic(run_id)
          _ = LemonCore.Bus.unsubscribe(topic)

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
            spawn(fn ->
              # Remove 👀 and add result reaction
              _ = Outbound.delete_own_reaction(channel_id, user_msg_id, "👀")
              _ = Outbound.create_reaction(channel_id, user_msg_id, reaction_emoji)
            end)

          if Code.ensure_loaded?(LemonCore.Bus) and
               function_exported?(LemonCore.Bus, :unsubscribe, 1) do
            topic = LemonCore.Bus.session_topic(matched_sk)
            _ = LemonCore.Bus.unsubscribe(topic)
          end

          %{state | reaction_runs: Map.delete(state.reaction_runs, matched_sk)}

        _ ->
          state
      end

    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  # Approval requests
  def handle_info(%LemonCore.Event{type: :approval_requested, payload: payload}, state) do
    _ = spawn(fn -> maybe_send_approval_request(state, payload) end)
    {:noreply, state}
  end

  def handle_info(%LemonCore.Event{type: :approval_resolved}, state), do: {:noreply, state}

  def handle_info({:discord_event, {:THREAD_CREATE, thread, _ws_state}}, state) do
    state = maybe_handle_thread_create(thread, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp maybe_handle_message(message, state) do
    with true <- not_self_message?(message, state),
         {:ok, inbound} <- normalize_message_inbound(message, state),
         true <- allowed_inbound?(inbound, state),
         true <- binding_allowed?(inbound, state),
         :new <- check_dedupe(inbound, state) do
      _ = maybe_index_known_target(state, inbound, message)
      handle_inbound_message(state, inbound)
    else
      :seen ->
        Logger.debug("discord: dropping duplicate message")
        state

      _ ->
        state
    end
  rescue
    error ->
      Logger.warning("discord inbound message handling failed: #{inspect(error)}")
      state
  end

  defp check_dedupe(inbound, state) do
    key = TransportShared.inbound_message_dedupe_key(inbound)

    case LemonCore.Dedupe.Ets.check_and_mark(@dedupe_table, key, state.dedupe_ttl_ms) do
      :seen -> :seen
      :new -> check_and_mark_persistent_dedupe(inbound, key, state)
    end
  end

  defp check_and_mark_persistent_dedupe(inbound, key, state) do
    store_key = persistent_dedupe_key(inbound, key)
    now = Event.now_ms()

    case Store.get(:idempotency, store_key) do
      %{"inserted_at_ms" => inserted_at_ms} when is_integer(inserted_at_ms) ->
        if now - inserted_at_ms <= state.dedupe_ttl_ms do
          :seen
        else
          :ok = Store.put(:idempotency, store_key, %{"inserted_at_ms" => now})
          :new
        end

      _ ->
        :ok = Store.put(:idempotency, store_key, %{"inserted_at_ms" => now})
        :new
    end
  rescue
    _ -> :new
  end

  defp persistent_dedupe_key(inbound, key) do
    account_id = inbound.account_id || "default"
    encoded = key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
    "#{@persistent_dedupe_scope}:#{account_id}:#{encoded}"
  end

  defp handle_inbound_message(state, inbound) do
    text = inbound.message.text || ""

    # Auto-put attachments if enabled (before any other processing)
    _ =
      if FileOperations.should_auto_put?(state, inbound) do
        spawn(fn -> FileOperations.handle_attachment_auto_put(state, inbound) end)
      end

    # Check if this is model picker input
    {state, handled_picker?} = maybe_handle_model_picker_input(state, inbound, text)

    if handled_picker? do
      state
    else
      cond do
        # Check for trigger mode (ignore in guilds if mentions-only)
        should_ignore_for_trigger?(state, inbound, text) ->
          state

        # Non-command messages get buffered for debouncing
        true ->
          enqueue_buffer(state, inbound)
      end
    end
  rescue
    e ->
      Logger.warning(
        "discord inbound handler crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

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
    msg_entry = %{text: inbound.message.text || "", reply_to_id: inbound.message.reply_to_id}

    debounce_ref = make_ref()
    Process.send_after(self(), {:debounce_flush, scope_key, debounce_ref}, state.debounce_ms)

    existing = Map.get(state.buffers, scope_key)

    buffer =
      if existing do
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
    {queue_override, inbound} = apply_queue_prefix(inbound)

    channel_id = inbound.meta[:channel_id]
    thread_id = inbound.meta[:thread_id]
    user_msg_id = inbound.meta[:user_msg_id]

    # Set 👀 reaction on user message
    progress_msg_id =
      if is_integer(channel_id) and is_integer(user_msg_id) do
        case Outbound.create_reaction(channel_id, user_msg_id, "👀") do
          {:ok, _} -> user_msg_id
          _ -> nil
        end
      else
        nil
      end

    scope =
      if is_integer(channel_id),
        do: %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id},
        else: nil

    session_key = build_session_key(state, inbound, scope)

    {model_hint, model_scope} = resolve_model_hint(state, session_key, channel_id, thread_id)
    {thinking_hint, thinking_scope} = resolve_thinking_hint(state, channel_id, thread_id)

    meta =
      (inbound.meta || %{})
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

    # Track for reaction updates
    state =
      if is_integer(progress_msg_id) and is_binary(session_key) do
        maybe_subscribe_to_session(session_key)

        reaction_run = %{
          channel_id: channel_id,
          thread_id: thread_id,
          user_msg_id: user_msg_id,
          session_key: session_key
        }

        %{state | reaction_runs: Map.put(state.reaction_runs, session_key, reaction_run)}
      else
        state
      end

    meta =
      case meta[:resume] do
        %ResumeToken{engine: "lemon"} = resume -> Map.put(meta, :resume, resume)
        _ -> Map.delete(meta, :resume)
      end

    # Apply a native resume selected by /resume. Stale vendor selections remain
    # stored for rollback, but never affect a native channel run.
    meta =
      if is_nil(meta[:resume]) do
        stored_resume_key = {state.account_id, channel_id, thread_id}

        case LemonCore.Store.get(:discord_selected_resume, stored_resume_key) do
          %ResumeToken{engine: "lemon"} = resume ->
            _ = LemonCore.Store.delete(:discord_selected_resume, stored_resume_key)
            Map.put(meta, :resume, resume)

          _ ->
            meta
        end
      else
        meta
      end

    case ResumeSelection.extract_explicit_resume_and_strip(inbound.message.text) do
      {:unsupported, engine} ->
        _ = send_channel_message(channel_id, unsupported_resume_message(engine))
        state

      {%ResumeToken{engine: "lemon"} = explicit_resume, stripped_prompt} ->
        inbound =
          %{
            inbound
            | meta:
                if(is_nil(meta[:resume]), do: Map.put(meta, :resume, explicit_resume), else: meta),
              message: Map.put(inbound.message || %{}, :text, stripped_prompt)
          }

        _ = route_to_router(inbound)
        state

      {%ResumeToken{engine: engine}, _stripped_prompt} ->
        _ = send_channel_message(channel_id, unsupported_resume_message(engine))
        state

      {_explicit_resume, stripped_prompt} ->
        inbound = %{
          inbound
          | meta: meta,
            message: Map.put(inbound.message || %{}, :text, stripped_prompt)
        }

        _ = route_to_router(inbound)
        state
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
    interaction_type = map_get(interaction, :type)

    case interaction_type do
      # Application Command (slash command)
      2 -> handle_slash_command(interaction, state)
      # Message Component (button, select menu)
      3 -> handle_component_interaction(interaction, state)
      _ -> state
    end
  rescue
    error ->
      Logger.warning("discord interaction handling failed: #{inspect(error)}")
      state
  end

  defp handle_slash_command(interaction, state) do
    name = interaction |> map_get(:data) |> map_get(:name)
    inbound = interaction_to_inbound(interaction, "/#{name || "unknown"}", state)

    if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
      dispatch_slash_command(name, interaction, state)
    else
      respond_ephemeral(interaction, "This command is not available in this Discord location.")
      state
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

      command when command in ~w(status usage agents tasks compress commands help bg btw) ->
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

      "reload" ->
        handle_reload_interaction(interaction, state)

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
    values = interaction |> map_get(:data) |> map_get(:values) || []

    cond do
      String.starts_with?(custom_id || "", @cancel_callback_prefix <> ":") ->
        handle_cancel_component(interaction, custom_id)
        state

      String.starts_with?(custom_id || "", @idle_keepalive_continue_prefix) ->
        handle_keepalive_component(interaction, custom_id, :continue)
        state

      String.starts_with?(custom_id || "", @idle_keepalive_stop_prefix) ->
        handle_keepalive_component(interaction, custom_id, :cancel)
        state

      String.starts_with?(custom_id || "", @model_callback_prefix) ->
        handle_model_component(interaction, state, custom_id, values)

      true ->
        handle_approval_component(interaction, custom_id)
        state
    end
  rescue
    _ -> state
  end

  # ============================================================================
  # /lemon Command
  # ============================================================================

  defp handle_lemon_interaction(interaction, state) do
    prompt = option_value(interaction, "prompt")

    if is_binary(prompt) and String.trim(prompt) != "" do
      respond_ephemeral(interaction, "Queued")

      inbound = interaction_to_inbound(interaction, prompt, state)

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        submit_inbound_now(state, inbound)
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
      respond_ephemeral(interaction, "Redirecting…")

      inbound = interaction_to_inbound(interaction, correction, state)
      inbound = %{inbound | meta: Map.put(inbound.meta || %{}, :queue_mode, :redirect)}

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        submit_inbound_now(state, inbound)
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
      respond_ephemeral(interaction, response)

      inbound = interaction_to_inbound(interaction, prompt, state)
      inbound = %{inbound | meta: Map.put(inbound.meta || %{}, :queue_mode, queue_mode)}

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        submit_inbound_now(state, inbound)
      else
        state
      end
    else
      respond_ephemeral(interaction, "Prompt cannot be empty.")
      state
    end
  end

  defp handle_portable_interaction(interaction, state, command) do
    args =
      case command do
        "help" -> option_value(interaction, "filter")
        "bg" -> option_value(interaction, "prompt")
        "btw" -> option_value(interaction, "question")
        _ -> ""
      end

    inbound = interaction_to_inbound(interaction, "/#{command} #{args}", state)

    if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
      session_key = inbound.meta[:session_key]
      channel_id = inbound.meta[:channel_id]
      thread_id = inbound.meta[:thread_id]
      scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}

      context = %{
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
        respond_ephemeral(interaction, "Answering side question…")
        _ = Task.start(fn -> send_followup(interaction, run.()) end)
      else
        respond_ephemeral(interaction, run.())
      end
    else
      respond_ephemeral(interaction, "This command is not available in this Discord location.")
    end

    state
  rescue
    _ ->
      respond_ephemeral(interaction, "Command failed safely.")
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
        channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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

    Task.start(fn ->
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
  rescue
    _ -> :ok
  end

  # ============================================================================
  # /model Command
  # ============================================================================

  defp handle_model_interaction(interaction, state) do
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
    thread_id = interaction_thread_id(interaction)
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
              scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
              agent_id = BindingResolver.resolve_agent_id(scope)
              user_id = interaction_user_id(interaction)
              guild_id = interaction |> map_get(:guild_id) |> parse_id()
              peer_kind = if is_integer(guild_id), do: :group, else: :dm

              _sk =
                session_key_for(
                  agent_id,
                  state.account_id,
                  peer_kind,
                  channel_id,
                  user_id,
                  thread_id,
                  guild_id
                )

              LemonCore.Store.put(
                :discord_selected_resume,
                {state.account_id, channel_id, thread_id},
                resume
              )

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
                  LemonCore.Store.put(
                    :discord_selected_resume,
                    {state.account_id, channel_id, thread_id},
                    resume
                  )

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

    if Code.ensure_loaded?(RouterBridge) and function_exported?(RouterBridge, :active_run, 1) do
      case RouterBridge.active_run(session_key) do
        {:ok, run_id} ->
          if Code.ensure_loaded?(LemonChannels.Runtime) and
               function_exported?(LemonChannels.Runtime, :cancel_by_run_id, 2) do
            LemonChannels.Runtime.cancel_by_run_id(run_id, :user_requested)
          else
            _ = RouterBridge.abort_run(run_id, :user_requested)
          end

          respond_ephemeral(interaction, "Cancelling run...")

        _ ->
          respond_ephemeral(interaction, "No active run to cancel.")
      end
    else
      respond_ephemeral(interaction, "Cancel not available.")
    end

    state
  end

  defp handle_checkpoint_interaction(interaction, state) do
    args = checkpoint_interaction_args(interaction)

    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction |> map_get(:channel_id) |> parse_id(),
      topic_id: interaction_thread_id(interaction)
    }

    respond_ephemeral(
      interaction,
      LemonChannels.CheckpointStatusMessage.handle(args,
        agent_id: BindingResolver.resolve_agent_id(scope),
        session_key: interaction_session_key(interaction, state)
      )
    )

    state
  end

  defp handle_rollback_interaction(interaction, state) do
    args = checkpoint_interaction_args(interaction)

    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction |> map_get(:channel_id) |> parse_id(),
      topic_id: interaction_thread_id(interaction)
    }

    respond_ephemeral(
      interaction,
      LemonChannels.CheckpointStatusMessage.handle_rollback(args,
        agent_id: BindingResolver.resolve_agent_id(scope),
        session_key: interaction_session_key(interaction, state)
      )
    )

    state
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
      chat_id: interaction |> map_get(:channel_id) |> parse_id(),
      topic_id: interaction_thread_id(interaction)
    }

    respond_ephemeral(
      interaction,
      LemonChannels.GoalStatusMessage.handle(session_key, args,
        agent_id: BindingResolver.resolve_agent_id(scope),
        meta: %{transport: "discord"}
      )
    )

    state
  end

  defp handle_kanban_interaction(interaction, state) do
    args = kanban_interaction_args(interaction)

    scope = %ChatScope{
      transport: :discord,
      chat_id: interaction |> map_get(:channel_id) |> parse_id(),
      topic_id: interaction_thread_id(interaction)
    }

    agent_id = BindingResolver.resolve_agent_id(scope)

    respond_ephemeral(
      interaction,
      LemonChannels.KanbanStatusMessage.handle(args,
        owner: agent_id,
        author: agent_id,
        worker_id: agent_id,
        workspace: BindingResolver.resolve_cwd(scope),
        meta: %{transport: "discord"}
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
        confirm? = nested_option_value(interaction, "restore", "confirm") == true
        confirm_arg = if confirm?, do: " confirm", else: ""
        "restore" <> value_arg(checkpoint_id) <> confirm_arg

      _ ->
        "status"
    end
  end

  defp kanban_interaction_args(interaction) do
    subcommand = session_subcommand(interaction) || "boards"

    case subcommand do
      "boards" ->
        "boards" <> kanban_interaction_options(interaction, "boards", [:status, :owner, :limit])

      "create" ->
        name = nested_option_value(interaction, "create", "name")

        "create" <>
          kanban_interaction_options(interaction, "create", [:workspace]) <> value_arg(name)

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
          kanban_interaction_options(interaction, "task_create", [
            :priority,
            :assignee,
            :worker_profile
          ]) <> value_arg(title)

      "task_update" ->
        task_id = nested_option_value(interaction, "task_update", "task_id")

        "task update" <>
          value_arg(task_id) <>
          kanban_interaction_options(interaction, "task_update", [
            :status,
            :priority,
            :assignee,
            :worker_profile
          ])

      "comment" ->
        task_id = nested_option_value(interaction, "comment", "task_id")
        body = nested_option_value(interaction, "comment", "body")
        "comment" <> value_arg(task_id) <> value_arg(body)

      "dispatch_start" ->
        board_id = nested_option_value(interaction, "dispatch_start", "board_id")

        "dispatch start" <>
          value_arg(board_id) <>
          kanban_interaction_options(interaction, "dispatch_start", [
            :max_concurrency,
            :worker_profile
          ])

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

  defp handle_cancel_component(interaction, custom_id) do
    run_id = String.trim_leading(custom_id, @cancel_callback_prefix <> ":")

    if is_binary(run_id) and run_id != "" do
      if Code.ensure_loaded?(LemonChannels.Runtime) and
           function_exported?(LemonChannels.Runtime, :cancel_by_run_id, 2) do
        LemonChannels.Runtime.cancel_by_run_id(run_id, :user_requested)
      end
    end

    update_interaction(interaction, "Cancelling...", [])
  end

  defp handle_keepalive_component(interaction, custom_id, decision) do
    run_id =
      case decision do
        :continue -> String.trim_leading(custom_id, @idle_keepalive_continue_prefix)
        :cancel -> String.trim_leading(custom_id, @idle_keepalive_stop_prefix)
      end

    if is_binary(run_id) and run_id != "" do
      if Code.ensure_loaded?(LemonChannels.Runtime) and
           function_exported?(LemonChannels.Runtime, :keep_run_alive, 2) do
        LemonChannels.Runtime.keep_run_alive(run_id, decision)
      end
    end

    msg = if decision == :continue, do: "Continuing run.", else: "Stopping run."
    update_interaction(interaction, msg, [])
  end

  # ============================================================================
  # /trigger Command
  # ============================================================================

  defp handle_trigger_interaction(interaction, state) do
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
  rescue
    _ -> state
  end

  defp handle_file_put_interaction(interaction, state) do
    attachment = FileOperations.extract_resolved_attachment(interaction, "put", "attachment")
    dest_path = nested_option_value(interaction, "put", "path")
    force = nested_option_value(interaction, "put", "force") == true

    if is_nil(attachment) do
      respond_ephemeral(interaction, "Please attach a file to upload.")
    else
      case FileOperations.handle_file_put(state, interaction, attachment, dest_path, force) do
        {:ok, msg} -> respond_ephemeral(interaction, msg)
        {:error, msg} -> respond_ephemeral(interaction, msg)
      end
    end
  rescue
    _ -> respond_ephemeral(interaction, "File upload failed.")
  end

  defp handle_file_get_interaction(interaction, state) do
    file_path = nested_option_value(interaction, "get", "path")

    if is_nil(file_path) or file_path == "" do
      respond_ephemeral(interaction, "Please specify a file path.")
    else
      case FileOperations.handle_file_get(state, interaction, file_path) do
        {:ok, msg} -> respond_ephemeral(interaction, msg)
        {:error, msg} -> respond_ephemeral(interaction, msg)
      end
    end
  rescue
    _ -> respond_ephemeral(interaction, "File download failed.")
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
  # /reload Command
  # ============================================================================

  defp handle_reload_interaction(interaction, state) do
    respond_ephemeral(interaction, "Recompiling...")

    case IEx.Helpers.recompile() do
      :ok ->
        send_followup(interaction, "Recompile complete.")

      :noop ->
        send_followup(interaction, "Nothing to recompile — code is up to date.")

      {:error, _} ->
        send_followup(interaction, "Recompile failed — check the build output.")
    end

    state
  rescue
    _ -> state
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

      # Try forum post first, fall back to regular thread
      case create_thread_or_forum_post(channel_id, topic_name, initial_msg) do
        {:ok, thread} ->
          thread_id = map_get(thread, :id)
          send_followup(interaction, "Created: <##{thread_id}>")
          state

        {:error, reason} ->
          send_followup(interaction, "Failed to create thread: #{inspect(reason)}")
          state
      end
    end
  rescue
    _ -> state
  end

  defp create_thread_or_forum_post(channel_id, name, initial_message)
       when is_integer(channel_id) do
    # First try as a forum channel (create_in_forum)
    case Nostrum.Api.Thread.create_in_forum(channel_id, %{
           name: name,
           message: %{content: initial_message},
           auto_archive_duration: 10_080
         }) do
      {:ok, channel} ->
        {:ok, channel}

      {:error, _} ->
        # Fall back to regular thread creation
        Nostrum.Api.Thread.create(channel_id, %{
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
      spawn(fn ->
        _ = Nostrum.Api.Thread.join(thread_id)
      end)
    end

    state
  rescue
    _ -> state
  end

  # Model picker input from regular messages (text matching for DMs)
  defp maybe_handle_model_picker_input(state, _inbound, _text) do
    # Discord uses component interactions for model picker, not text input
    {state, false}
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
          trigger = resolve_trigger_mode(account_id, channel_id, thread_id)
          trigger.mode == :mentions and not explicit_mention?(state, inbound)
        else
          false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp resolve_trigger_mode(account_id, channel_id, nil) do
    primary = TriggerMode.resolve(account_id, channel_id, nil)

    if primary.mode == :mentions do
      fallback = TriggerMode.resolve(account_id, channel_id, channel_id)

      if fallback.source == :topic, do: fallback, else: primary
    else
      primary
    end
  end

  defp resolve_trigger_mode(account_id, channel_id, thread_id) do
    TriggerMode.resolve(account_id, channel_id, thread_id)
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
  rescue
    _ -> false
  end

  defp reply_to_bot?(%{meta: %{reply_to_author_id: author_id}}, %{bot_user_id: bot_id})
       when is_integer(author_id) and is_integer(bot_id),
       do: author_id == bot_id

  defp reply_to_bot?(_inbound, _state), do: false

  # ============================================================================
  # Approval Handling
  # ============================================================================

  # `:approval_requested` payloads are `Events.ApprovalRequested` structs carrying an
  # `Events.ApprovalPending`; a legacy map is coerced into that pair so the whole record is
  # read by field. A payload that will not coerce drops out of the `with` as a no-op.
  defp maybe_send_approval_request(state, payload) when is_map(payload) do
    with %Events.ApprovalRequested{approval_id: approval_id, pending: pending} <-
           Events.coerce(:approval_requested, payload),
         %Events.ApprovalPending{session_key: session_key, tool: tool, action: action} <-
           pending,
         true <- is_binary(approval_id) and is_binary(session_key),
         %{
           kind: :channel_peer,
           channel_id: "discord",
           account_id: account_id,
           peer_id: peer_id,
           thread_id: _thread_id
         } <-
           SessionKey.parse(session_key),
         true <- is_nil(account_id) or account_id == state.account_id,
         channel_id when is_integer(channel_id) <- parse_id(peer_id) do
      text = "**Approval requested:** #{tool}\n**Action:** #{format_action(action)}"

      components = [
        StatusRenderer.action_row([
          StatusRenderer.button("Approve once", "#{approval_id}|once", style: :success),
          StatusRenderer.button("Deny", "#{approval_id}|deny", style: :danger)
        ]),
        StatusRenderer.action_row([
          StatusRenderer.button("Session", "#{approval_id}|session", style: :primary),
          StatusRenderer.button("Agent", "#{approval_id}|agent", style: :primary),
          StatusRenderer.button("Global", "#{approval_id}|global", style: :primary)
        ])
      ]

      _ = Outbound.send_with_components(channel_id, text, components)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_send_approval_request(_state, _payload), do: :ok

  defp handle_approval_component(interaction, custom_id) do
    case parse_approval_callback(custom_id) do
      {approval_id, decision} when is_binary(approval_id) ->
        if Code.ensure_loaded?(LemonCore.ExecApprovals) and
             function_exported?(LemonCore.ExecApprovals, :resolve, 2) do
          _ = LemonCore.ExecApprovals.resolve(approval_id, decision)
        end

        update_interaction(interaction, "Approval: #{decision_label(decision)}", [])

      _ ->
        acknowledge_interaction(interaction)
    end
  end

  defp parse_approval_callback(data) when is_binary(data) do
    case String.split(data, "|", parts: 2) do
      [id, decision] when id != "" and decision != "" ->
        parsed =
          case decision do
            "once" -> :approve_once
            "deny" -> :deny
            "session" -> :approve_session
            "agent" -> :approve_agent
            "global" -> :approve_global
            _ -> nil
          end

        if parsed, do: {id, parsed}, else: {nil, nil}

      _ ->
        {nil, nil}
    end
  end

  defp parse_approval_callback(_), do: {nil, nil}

  defp decision_label(:approve_once), do: "Approved (once)"
  defp decision_label(:deny), do: "Denied"
  defp decision_label(:approve_session), do: "Approved (session)"
  defp decision_label(:approve_agent), do: "Approved (agent)"
  defp decision_label(:approve_global), do: "Approved (global)"
  defp decision_label(_), do: "Unknown"

  defp format_action(action) when is_map(action) do
    cond do
      is_binary(action["cmd"]) -> action["cmd"]
      is_binary(action[:cmd]) -> action[:cmd]
      true -> inspect(action)
    end
  end

  defp format_action(other), do: inspect(other)

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
  rescue
    _ -> thinking_usage()
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

  defp thinking_usage, do: "Usage: `/thinking [off|minimal|low|medium|high|xhigh|clear|status]`"

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
  rescue
    _ -> "Usage: `/cwd [project_id|path|clear]`"
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
        case Cwd.default_cwd() do
          cwd when is_binary(cwd) and cwd != "" -> Path.expand(cwd)
          _ -> "(not configured)"
        end
    end
  rescue
    _ -> "(not configured)"
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
  rescue
    _ -> base_msg
  end

  # ============================================================================
  # CWD / Project Helpers
  # ============================================================================

  defp maybe_select_project_for_scope(%ChatScope{} = scope, selector) when is_binary(selector) do
    sel = String.trim(selector)

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
            _ -> Path.expand(sel, base)
          end

        if File.dir?(expanded) do
          id = Path.basename(expanded)
          ProjectBindingStore.put_dynamic(id, %{root: expanded})
          ProjectBindingStore.put_override(scope, id)
          {:ok, %{id: id, root: expanded}}
        else
          {:error, "Project path does not exist: #{expanded}"}
        end

      true ->
        case BindingResolver.lookup_project(sel) do
          %{root: root} when is_binary(root) and byte_size(root) > 0 ->
            root = Path.expand(root)

            if File.dir?(root) do
              ProjectBindingStore.put_override(scope, sel)
              {:ok, %{id: sel, root: root}}
            else
              {:error, "Project root does not exist: #{root}"}
            end

          _ ->
            {:error, "Unknown project: #{sel}"}
        end
    end
  rescue
    _ -> {:error, "Failed to select project."}
  end

  defp looks_like_path?(s) when is_binary(s) do
    String.starts_with?(s, "/") or String.starts_with?(s, "~") or
      String.starts_with?(s, ".") or String.contains?(s, "/")
  end

  defp scope_has_cwd_override?(%ChatScope{} = scope) do
    case BindingResolver.get_project_override(scope) do
      override when is_binary(override) and override != "" -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp clear_cwd_override(%ChatScope{} = scope) do
    _ = ProjectBindingStore.delete_override(scope)
    :ok
  rescue
    _ -> :ok
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

    _ = safe_interaction_response(interaction, payload)
    :ok
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

    _ = safe_interaction_response(interaction, payload)
    :ok
  end

  defp update_interaction(interaction, content, components) do
    payload = %{
      type: 7,
      data: %{content: content, components: components, allowed_mentions: safe_allowed_mentions()}
    }

    _ = safe_interaction_response(interaction, payload)
    :ok
  end

  defp acknowledge_interaction(interaction) do
    _ = safe_interaction_response(interaction, %{type: 6})
    :ok
  end

  defp safe_interaction_response(interaction, payload) do
    result =
      case Application.get_env(:lemon_channels, :discord_interaction_responder) do
        responder when is_function(responder, 2) -> responder.(interaction, payload)
        {mod, fun} when is_atom(mod) and is_atom(fun) -> apply(mod, fun, [interaction, payload])
        _ -> Interaction.create_response(interaction, payload)
      end

    record_slash_client_click_proof(interaction, payload, :completed)
    result
  rescue
    error ->
      record_slash_client_click_proof(interaction, payload, :failed)
      Logger.warning("discord interaction response failed: #{inspect(error)}")
      :ok
  end

  defp record_slash_client_click_proof(interaction, payload, status) do
    if real_slash_client_interaction?(interaction) do
      now = DateTime.utc_now()
      command = interaction |> map_get(:data) |> map_get(:name) |> safe_proof_value("unknown")
      response_type = map_get(payload, :type)
      safe_mentions = safe_interaction_mentions?(payload)
      completed_count = if status == :completed and safe_mentions, do: 2, else: 1
      failed_count = if status == :completed and safe_mentions, do: 0, else: 1

      proof = %{
        proof: "discord_slash_client_click",
        proof_object: "lemon.discord_slash_client_click",
        proof_scope: "discord_slash_client_click_observed",
        status: if(failed_count == 0, do: "completed", else: "failed"),
        completed_count: completed_count,
        failed_count: failed_count,
        skipped_count: 0,
        generated_at: DateTime.to_iso8601(now),
        coverage: %{
          registered_command_count: length(slash_commands()),
          client_click_command_count: 1,
          real_client_click_proof: failed_count == 0
        },
        checks: [
          %{
            name: "discord_slash_client_click_observed",
            status: "completed",
            proof_scope: "discord slash client click observed"
          },
          %{
            name: "discord_slash_client_click_safe_mentions",
            status: if(safe_mentions, do: "completed", else: "failed"),
            proof_scope: "discord slash client click observed"
          }
        ],
        details: %{
          command: command,
          interaction_type: map_get(interaction, :type),
          response_type: response_type,
          ephemeral_response: ephemeral_response?(payload),
          safe_mentions_disabled: safe_mentions,
          live_fields: %{
            application_id_present: present?(map_get(interaction, :application_id)),
            token_present: present?(map_get(interaction, :token)),
            member_present: present?(map_get(interaction, :member)),
            user_present: present?(map_get(interaction, :user))
          }
        },
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_raw_interaction_tokens: false,
          includes_raw_application_ids: false,
          includes_raw_channel_ids: false,
          includes_raw_user_ids: false,
          includes_raw_message_bodies: false
        }
      }

      write_slash_client_click_proof(proof, now)
    end
  rescue
    error ->
      Logger.debug("discord slash client-click proof write failed: #{inspect(error)}")
      :ok
  end

  defp real_slash_client_interaction?(interaction) do
    map_get(interaction, :type) == 2 and
      present?(map_get(interaction, :application_id)) and
      present?(map_get(interaction, :token))
  end

  defp write_slash_client_click_proof(proof, now) do
    dir =
      Application.get_env(
        :lemon_channels,
        :discord_client_click_proof_dir,
        Path.join([File.cwd!(), ".lemon", "proofs"])
      )

    File.mkdir_p!(dir)
    json = Jason.encode!(proof, pretty: true)
    latest = Path.join(dir, "discord-slash-client-click-proof-latest.json")

    archive =
      Path.join(
        dir,
        "discord-slash-client-click-proof-" <>
          (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"
      )

    File.write!(latest, json <> "\n")
    File.write!(archive, json <> "\n")
    :ok
  end

  defp safe_interaction_mentions?(%{data: data}) when is_map(data) do
    case map_get(data, :allowed_mentions) do
      %{parse: [], replied_user: false} -> true
      %{"parse" => [], "replied_user" => false} -> true
      _ -> false
    end
  end

  defp safe_interaction_mentions?(%{type: 6}), do: true
  defp safe_interaction_mentions?(_), do: false

  defp ephemeral_response?(payload) do
    flags =
      payload
      |> map_get(:data)
      |> map_get(:flags)

    is_integer(flags) and Bitwise.band(flags, 64) == 64
  end

  defp safe_proof_value(value, default) when is_binary(value) do
    if String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}$/), do: value, else: default
  end

  defp safe_proof_value(_value, default), do: default

  defp send_followup(interaction, content) do
    token = map_get(interaction, :token)
    app_id = map_get(interaction, :application_id)

    if is_binary(token) and app_id do
      Nostrum.Api.Webhook.execute(app_id, token, %{
        content: content,
        flags: 64,
        allowed_mentions: safe_allowed_mentions()
      })
    end
  rescue
    _ -> :ok
  end

  defp send_channel_message(channel_id, text) when is_integer(channel_id) and is_binary(text) do
    Nostrum.Api.Message.create(channel_id, %{
      content: text,
      allowed_mentions: safe_allowed_mentions()
    })
  rescue
    _ -> :ok
  end

  defp safe_allowed_mentions, do: %{parse: [], replied_user: false}

  # ============================================================================
  # Session & Routing Helpers
  # ============================================================================

  defp interaction_to_inbound(interaction, prompt, state) do
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
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

  defp interaction_thread_id(interaction) do
    channel = map_get(interaction, :channel)

    cond do
      # Has thread metadata — this is a thread/forum post
      match?(%{}, map_get(channel, :thread_metadata)) ->
        interaction |> map_get(:channel_id) |> parse_id()

      # Check if parent_id is set (forum threads have parent_id)
      is_integer(map_get(channel, :parent_id) |> parse_id()) ->
        interaction |> map_get(:channel_id) |> parse_id()

      true ->
        nil
    end
  end

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

  defp route_to_router(%InboundMessage{} = inbound) do
    case LemonChannels.Runtime.submit_inbound(inbound) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("discord inbound routing failed: #{inspect(reason)}")
        :ok
    end
  end

  defp safe_delete_chat_state(key) do
    ChatStateStore.delete(key)
  rescue
    _ -> :ok
  end

  defp maybe_subscribe_to_session(session_key) when is_binary(session_key) do
    if Code.ensure_loaded?(LemonCore.Bus) and function_exported?(LemonCore.Bus, :subscribe, 1) do
      topic = LemonCore.Bus.session_topic(session_key)
      _ = LemonCore.Bus.subscribe(topic)
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

  defp run_completed_ok?(event) do
    case event.payload do
      %{completed: %{ok: ok}} when is_boolean(ok) -> ok
      %{ok: ok} when is_boolean(ok) -> ok
      _ -> true
    end
  end

  defp maybe_index_known_target(state, %InboundMessage{} = inbound, message) do
    account_id = state.account_id || inbound.account_id || "default"
    channel_id = inbound.meta[:channel_id] |> parse_id()
    thread_id = inbound.meta[:thread_id] |> parse_id()

    with true <- is_binary(account_id) and account_id != "",
         true <- is_integer(channel_id) do
      key = {account_id, channel_id, thread_id}
      existing = KnownTargetStore.get(key) || %{}
      now = System.system_time(:millisecond)

      channel = map_get(message, :channel)
      thread = map_get(message, :thread)
      channel_type = map_get(channel, :type) |> parse_id()
      thread_channel? = channel_type in [10, 11, 12]

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
          channel_name:
            coalesce_text(
              if(thread_channel?, do: nil, else: map_get(channel, :name)),
              existing,
              :channel_name
            ),
          thread_name:
            coalesce_text(
              map_get(thread, :name) || if(thread_channel?, do: map_get(channel, :name)),
              existing,
              :thread_name
            ),
          updated_at_ms: now,
          first_seen_at_ms: field(existing, :first_seen_at_ms) || now
        }
        |> maybe_put(:last_message_id, inbound.meta[:user_msg_id] |> parse_id())

      if should_persist_known_target?(existing, entry, now) do
        _ = KnownTargetStore.put(key, entry)
      end
    end

    :ok
  rescue
    _ -> :ok
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

    guild_allowed? and channel_allowed?
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
  # Nostrum / Startup
  # ============================================================================

  defp start_consumer do
    case safe_start_consumer() do
      {:ok, pid} ->
        pid

      :ok ->
        nil

      {:error, reason} ->
        Logger.warning("discord consumer failed to start: #{inspect(reason)}")
        nil
    end
  end

  defp safe_start_consumer do
    __MODULE__.Consumer.start_link([])
  rescue
    error -> {:error, error}
  end

  defp ensure_nostrum_started(token) do
    Application.put_env(:nostrum, :token, token)

    Application.put_env(:nostrum, :gateway_intents, [
      :guilds,
      :guild_messages,
      :guild_message_reactions,
      :direct_messages,
      :direct_message_reactions,
      :message_content
    ])

    case Application.ensure_all_started(:nostrum) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp resolve_bot_token_secret(config) do
    secret_name = cfg_get(config, :bot_token_secret)

    if is_binary(secret_name) and secret_name != "",
      do: Secrets.fetch_value(secret_name),
      else: nil
  end

  defp resolve_token do
    Secrets.fetch_value("DISCORD_BOT_TOKEN") || System.get_env("DISCORD_BOT_TOKEN")
  end

  # ============================================================================
  # Nostrum Consumer
  # ============================================================================

  defmodule Consumer do
    @moduledoc false
    use Nostrum.Consumer

    @transport LemonChannels.Adapters.Discord.Transport

    def handle_event(event) do
      if pid = Process.whereis(@transport) do
        send(pid, {:discord_event, event})
      end
    end
  end
end

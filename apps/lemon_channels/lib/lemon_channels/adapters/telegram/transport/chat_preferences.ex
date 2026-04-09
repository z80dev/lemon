defmodule LemonChannels.Adapters.Telegram.Transport.ChatPreferences do
  @moduledoc """
  Telegram-local chat and topic preference commands.

  This module owns trigger-mode evaluation plus the `/trigger`, `/thinking`,
  and `/cwd` command flows extracted from the transport shell.
  """

  alias LemonChannels.Adapters.Telegram.ModelPolicyAdapter
  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.BindingResolver
  alias LemonChannels.Telegram.TriggerMode
  alias LemonCore.ChatScope
  alias LemonCore.ProjectBindingStore

  @thinking_levels ~w(off minimal low medium high xhigh)

  @type callbacks :: %{
          extract_chat_ids: (map() -> {integer() | nil, integer() | nil}),
          extract_message_ids: (map() -> {integer() | nil, integer() | nil, integer() | nil}),
          maybe_select_project_for_scope: (ChatScope.t(), binary() ->
                                             {:ok, map()} | {:error, binary()}),
          send_system_message: (map(), integer(), integer() | nil, integer() | nil, binary() ->
                                  any())
        }

  @spec should_ignore_for_trigger?(map(), map(), binary(), callbacks()) :: boolean()
  def should_ignore_for_trigger?(state, inbound, text, callbacks) do
    case inbound.peer.kind do
      :group ->
        trigger_mode = trigger_mode_for(state, inbound, callbacks)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      :channel ->
        trigger_mode = trigger_mode_for(state, inbound, callbacks)
        trigger_mode.mode == :mentions and not explicit_invocation?(state, inbound, text)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  @spec handle_trigger_command(map(), map(), callbacks()) :: map()
  def handle_trigger_command(state, inbound, callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)
    args = Commands.telegram_command_args(inbound.message.text, "trigger") || ""
    arg = String.downcase(String.trim(args || ""))
    account_id = state.account_id || "default"

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      ctx = {state, chat_id, thread_id, user_msg_id, account_id, scope, inbound, callbacks}

      case arg do
        "" ->
          current = TriggerMode.resolve(account_id, chat_id, thread_id)

          _ =
            callbacks.send_system_message.(
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
            callbacks.send_system_message.(
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

  @spec handle_thinking_command(map(), map(), callbacks()) :: map()
  def handle_thinking_command(state, inbound, callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)
    args = String.trim(Commands.telegram_command_args(inbound.message.text, "thinking") || "")

    if not is_integer(chat_id) do
      state
    else
      account_id = state.account_id || "default"
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

      case normalize_thinking_command_arg(args) do
        :status ->
          _ =
            callbacks.send_system_message.(
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
            callbacks.send_system_message.(
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
            callbacks.send_system_message.(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_thinking_set(scope, level)
            )

          state

        :invalid ->
          _ =
            callbacks.send_system_message.(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              thinking_usage()
            )

          state
      end
    end
  rescue
    _ -> state
  end

  @spec handle_cwd_command(map(), map(), callbacks()) :: map()
  def handle_cwd_command(state, inbound, callbacks) do
    {chat_id, thread_id, user_msg_id} = callbacks.extract_message_ids.(inbound)
    args = String.trim(Commands.telegram_command_args(inbound.message.text, "cwd") || "")

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

      case String.downcase(args) do
        "" ->
          _ =
            callbacks.send_system_message.(
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
            callbacks.send_system_message.(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              render_cwd_cleared(scope, had_override?)
            )

          state

        _ ->
          case callbacks.maybe_select_project_for_scope.(scope, args) do
            {:ok, %{root: root}} when is_binary(root) and root != "" ->
              _ =
                callbacks.send_system_message.(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  render_cwd_set(scope, root)
                )

              state

            {:error, msg} when is_binary(msg) ->
              _ = callbacks.send_system_message.(state, chat_id, thread_id, user_msg_id, msg)
              state

            _ ->
              _ =
                callbacks.send_system_message.(
                  state,
                  chat_id,
                  thread_id,
                  user_msg_id,
                  cwd_usage()
                )

              state
          end
      end
    end
  rescue
    _ -> state
  end

  defp trigger_mode_for(state, inbound, callbacks) do
    {chat_id, topic_id} = callbacks.extract_chat_ids.(inbound)
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

  defp topic_root_reply?(thread_id, reply) do
    is_integer(thread_id) and is_map(reply) and reply["message_id"] == thread_id
  end

  defp apply_trigger_mode(
         {state, chat_id, thread_id, user_msg_id, account_id, scope, inbound, callbacks},
         mode_atom,
         mode_str
       ) do
    with true <- trigger_change_allowed?(state, inbound, chat_id),
         :ok <- TriggerMode.set(scope, account_id, mode_atom) do
      _ =
        callbacks.send_system_message.(
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
          callbacks.send_system_message.(
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

  defp apply_trigger_clear(
         {state, chat_id, thread_id, user_msg_id, account_id, _scope, inbound, callbacks}
       ) do
    cond do
      is_nil(thread_id) ->
        _ =
          callbacks.send_system_message.(
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
          callbacks.send_system_message.(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "Cleared topic trigger override."
          )

        state

      true ->
        _ =
          callbacks.send_system_message.(
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

  defp format_thinking_line(level, source),
    do: ModelPolicyAdapter.format_thinking_line(level, source)

  defp default_thinking_preference(account_id, chat_id, thread_id),
    do: ModelPolicyAdapter.default_thinking_preference(account_id, chat_id, thread_id)

  defp put_default_thinking_preference(account_id, chat_id, thread_id, level),
    do: ModelPolicyAdapter.put_default_thinking_preference(account_id, chat_id, thread_id, level)

  defp clear_default_thinking_preference(account_id, chat_id, thread_id),
    do: ModelPolicyAdapter.clear_default_thinking_preference(account_id, chat_id, thread_id)

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end

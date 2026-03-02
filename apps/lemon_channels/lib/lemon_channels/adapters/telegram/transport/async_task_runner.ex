defmodule LemonChannels.Adapters.Telegram.Transport.AsyncTaskRunner do
  @moduledoc """
  Fire-and-forget async task execution for the Telegram transport.

  Wraps function execution in error-handling and delegates to the
  background task infrastructure. Used for side-effects that should not
  block the GenServer (e.g. sending approval request messages, setting
  reactions).
  """

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start an async task that runs `fun` in the background.

  The function is wrapped in error handling so failures are silently caught.
  Returns `:ok`.
  """
  def start_async_task(_state, fun) when is_function(fun, 0) do
    wrapped = fn ->
      try do
        fun.()
        :ok
      rescue
        _ -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    LemonCore.BackgroundTask.start(wrapped,
      supervisor: LemonChannels.Adapters.Telegram.AsyncSupervisor,
      allow_unsupervised: true
    )
  rescue
    _ -> :ok
  end

  def start_async_task(_state, _fun), do: :ok

  @doc """
  Subscribe to the exec_approvals Bus topic.
  """
  def maybe_subscribe_exec_approvals do
    if Code.ensure_loaded?(LemonCore.Bus) and function_exported?(LemonCore.Bus, :subscribe, 1) do
      _ = LemonCore.Bus.subscribe("exec_approvals")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Send an approval request message to the appropriate Telegram chat.
  """
  def maybe_send_approval_request(state, payload) when is_map(payload) do
    approval_id = payload[:approval_id] || payload["approval_id"]
    pending = payload[:pending] || payload["pending"] || %{}
    session_key = pending[:session_key] || pending["session_key"]

    with true <- is_binary(approval_id) and is_binary(session_key),
         %{
           kind: :channel_peer,
           channel_id: "telegram",
           account_id: account_id,
           peer_id: peer_id,
           thread_id: thread_id
         } <-
           LemonCore.SessionKey.parse(session_key),
         true <- is_nil(account_id) or account_id == state.account_id,
         chat_id when is_integer(chat_id) <- parse_int(peer_id) do
      tool = pending[:tool] || pending["tool"]
      action = pending[:action] || pending["action"]

      text =
        "Approval requested: #{tool}\n\n" <>
          "Action: #{format_action(action)}\n\n" <>
          "Choose:"

      reply_markup = %{
        "inline_keyboard" => [
          [
            %{"text" => "Approve once", "callback_data" => "#{approval_id}|once"},
            %{"text" => "Deny", "callback_data" => "#{approval_id}|deny"}
          ],
          [
            %{"text" => "Session", "callback_data" => "#{approval_id}|session"},
            %{"text" => "Agent", "callback_data" => "#{approval_id}|agent"},
            %{"text" => "Global", "callback_data" => "#{approval_id}|global"}
          ]
        ]
      }

      topic_id = parse_int(thread_id)

      opts =
        %{"reply_markup" => reply_markup}
        |> maybe_put("message_thread_id", topic_id)

      _ = state.api_mod.send_message(state.token, chat_id, text, opts)
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  def maybe_send_approval_request(_state, _payload), do: :ok

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp format_action(action) when is_map(action) do
    cond do
      is_binary(action["cmd"]) -> action["cmd"]
      is_binary(action[:cmd]) -> action[:cmd]
      true -> inspect(action)
    end
  end

  defp format_action(other), do: inspect(other)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end
end

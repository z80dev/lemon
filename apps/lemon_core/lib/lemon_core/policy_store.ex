defmodule LemonCore.PolicyStore do
  @moduledoc """
  The policy plane: per-session and per-chat policy rows.

  A session row (`:session_policies`, keyed by session key) holds the
  session's model and thinking overrides and its tool-policy override.
  `sessions.patch` and the channel `/model` commands write it;
  `LemonControlPlane.SessionLifecycle` deletes it with the session.

  A chat row (`:chat_policies`, keyed by a `t:chat_route/0`) holds the
  model and thinking defaults for every session of one channel route: a
  thread, a peer (chat), an account or a whole channel. The channel `/model`
  (future sessions), `/thinking` commands and `lemon policy` write it. A
  channel session's route comes from its session key (`chat_route/1`), so
  every surface driving that session resolves the same defaults.
  `resolve_chat/1` walks the route from most to least specific.

  Precedence between these rows, agent profiles and configuration defaults is
  decided once, in `LemonRouter.ModelSelection`. Configuration supplies
  defaults; there is no agent, channel-wide tool or global runtime policy row.

  Policy rows restrict execution, so reads fail closed: `{:ok, nil}` means the
  Store confirmed no row exists, and a backend error, call timeout or missing
  Store process is `{:error, :store_unavailable}`. Callers must reject the
  operation on that error rather than treat it as "no restriction".
  """

  alias LemonCore.{SessionKey, Store}

  @session_table :session_policies
  @chat_table :chat_policies
  @max_update_attempts 8

  @type fetched :: {:ok, map() | nil} | {:error, :store_unavailable}

  @typedoc """
  `{channel_id, account_id, peer_id, thread_id}`: a channel route. Each field
  narrows the previous one, so a `nil` is only followed by `nil`s:
  `{"chat", nil, nil, nil}` is channel-wide; `{"chat", "default", "peer-1", nil}`
  identifies one conversation.
  """
  @type chat_route :: {binary(), binary() | nil, binary() | nil, binary() | nil}

  @typedoc "Chat defaults resolved along a route, with the route each came from."
  @type chat_defaults :: %{
          model: binary() | nil,
          model_route: chat_route() | nil,
          thinking_level: binary() | nil,
          thinking_route: chat_route() | nil
        }

  @doc "Fetches the policy for the given session; `{:ok, nil}` only when none is stored."
  @spec fetch_session(binary()) :: fetched()
  def fetch_session(session_key), do: Store.fetch(@session_table, session_key)

  @doc "Stores a policy for the given session."
  @spec put_session(binary(), map()) :: :ok | {:error, term()}
  def put_session(session_key, policy), do: Store.put(@session_table, session_key, policy)

  @doc """
  Atomically replaces the session row with `fun.(current)`.

  `current` is the strictly fetched row (`nil` when none is stored). The write
  is a compare-and-swap against that exact row, retried on a concurrent change,
  so a failed read can never overwrite fields this caller did not see. Returns
  the stored row, `{:error, :store_unavailable}` when the row cannot be read,
  or the Store's write error.
  """
  @spec update_session(binary(), (map() | nil -> map())) :: {:ok, map()} | {:error, term()}
  def update_session(session_key, fun) when is_function(fun, 1),
    do: update_session(session_key, fun, @max_update_attempts)

  defp update_session(_session_key, _fun, 0), do: {:error, :concurrent_update}

  defp update_session(session_key, fun, attempts) do
    with {:ok, current} <- fetch_session(session_key),
         updated when is_map(updated) <- fun.(current) do
      case Store.compare_and_swap(@session_table, session_key, current, updated) do
        :ok -> {:ok, updated}
        {:error, :mismatch} -> update_session(session_key, fun, attempts - 1)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Deletes the policy for the given session."
  @spec delete_session(binary()) :: :ok | {:error, term()}
  def delete_session(session_key), do: Store.delete(@session_table, session_key)

  @doc """
  The chat route of a channel session key, or `nil` for a non-channel session.

  A sub-session (`:sub:<id>`) belongs to its chat's route.
  """
  @spec chat_route(binary() | nil) :: chat_route() | nil
  def chat_route(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{kind: :channel_peer} = parsed ->
        {parsed.channel_id, parsed.account_id, parsed.peer_id, parsed.thread_id}

      _ ->
        nil
    end
  end

  def chat_route(_session_key), do: nil

  @doc "Whether `route` is a well-formed `t:chat_route/0`."
  @spec chat_route?(term()) :: boolean()
  def chat_route?({channel_id, account_id, peer_id, thread_id})
      when is_binary(channel_id) and channel_id != "" do
    narrowing?([account_id, peer_id, thread_id])
  end

  def chat_route?(_route), do: false

  defp narrowing?([]), do: true
  defp narrowing?([nil | rest]), do: Enum.all?(rest, &is_nil/1)
  defp narrowing?([value | rest]) when is_binary(value) and value != "", do: narrowing?(rest)
  defp narrowing?(_fields), do: false

  @doc """
  The routes whose chat rows apply to `route`, most specific first: thread,
  peer, account, channel.
  """
  @spec route_chain(chat_route()) :: [chat_route()]
  def route_chain({channel_id, account_id, peer_id, _thread_id} = route) do
    true = chat_route?(route)

    Enum.uniq([
      route,
      {channel_id, account_id, peer_id, nil},
      {channel_id, account_id, nil, nil},
      {channel_id, nil, nil, nil}
    ])
  end

  @doc "Fetches the chat row stored for exactly `route`; `{:ok, nil}` only when none is stored."
  @spec fetch_chat(chat_route()) :: fetched() | {:error, :invalid_chat_route}
  def fetch_chat(route) do
    if chat_route?(route),
      do: Store.fetch(@chat_table, route),
      else: {:error, :invalid_chat_route}
  end

  @doc "Strict read of every chat row (the `lemon policy list` view)."
  @spec fetch_chats() :: {:ok, [{chat_route(), map()}]} | {:error, :store_unavailable}
  def fetch_chats do
    case Store.fetch_all(@chat_table) do
      {:ok, rows} -> {:ok, rows}
      {:error, _reason} -> {:error, :store_unavailable}
    end
  end

  @doc """
  Atomically replaces the chat row for `route` with `fun.(current)`.

  Like `update_session/2`, a compare-and-swap against the strictly fetched
  row. `fun` returning `nil` deletes the row. Returns the stored row (`nil`
  when deleted).
  """
  @spec update_chat(chat_route(), (map() | nil -> map() | nil)) ::
          {:ok, map() | nil} | {:error, term()}
  def update_chat(route, fun) when is_function(fun, 1) do
    if chat_route?(route),
      do: update_chat(route, fun, @max_update_attempts),
      else: {:error, :invalid_chat_route}
  end

  defp update_chat(_route, _fun, 0), do: {:error, :concurrent_update}

  defp update_chat(route, fun, attempts) do
    with {:ok, current} <- fetch_chat(route) do
      updated = fun.(current)

      result =
        case {current, updated} do
          {nil, nil} ->
            :ok

          {current, nil} ->
            Store.compare_and_delete(@chat_table, route, current)

          {current, row} when is_map(row) ->
            Store.compare_and_swap(@chat_table, route, current, row)
        end

      case result do
        :ok -> {:ok, updated}
        {:error, :mismatch} -> update_chat(route, fun, attempts - 1)
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Deletes the chat row for exactly `route`."
  @spec delete_chat(chat_route()) :: :ok | {:error, term()}
  def delete_chat(route) do
    if chat_route?(route),
      do: Store.delete(@chat_table, route),
      else: {:error, :invalid_chat_route}
  end

  @doc """
  Resolves the chat defaults that apply to `route` (or to a session key's
  route): the model of the most specific row that sets one, and likewise the
  thinking level. A non-channel session resolves to no defaults without a
  read; any unreadable row is `{:error, :store_unavailable}`.
  """
  @spec resolve_chat(chat_route() | binary() | nil) ::
          {:ok, chat_defaults()} | {:error, :store_unavailable}
  def resolve_chat(session_key) when is_binary(session_key),
    do: resolve_chat(chat_route(session_key))

  def resolve_chat(nil),
    do: {:ok, %{model: nil, model_route: nil, thinking_level: nil, thinking_route: nil}}

  def resolve_chat(route) do
    route
    |> route_chain()
    |> Enum.reduce_while(
      {:ok, %{model: nil, model_route: nil, thinking_level: nil, thinking_route: nil}},
      fn key, {:ok, acc} ->
        case Store.fetch(@chat_table, key) do
          {:ok, row} ->
            acc =
              acc
              |> inherit(:model, :model_route, row, key)
              |> inherit(:thinking_level, :thinking_route, row, key)

            if acc.model && acc.thinking_level, do: {:halt, {:ok, acc}}, else: {:cont, {:ok, acc}}

          {:error, _reason} ->
            {:halt, {:error, :store_unavailable}}
        end
      end
    )
  end

  defp inherit(acc, field, route_field, row, key) do
    case {Map.get(acc, field), row_value(row, field)} do
      {nil, value} when is_binary(value) -> %{acc | field => value, route_field => key}
      _ -> acc
    end
  end

  defp row_value(row, field) when is_map(row) do
    case Map.get(row, field) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp row_value(_row, _field), do: nil
end

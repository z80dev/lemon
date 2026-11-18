defmodule LemonControlPlane.Methods.SessionsEvents do
  @moduledoc """
  Bounded replay of native session broadcasts after an owner/branch-epoch cursor.

  Authorization is checked against current connection membership before and after
  the runtime read. Each replayed inner event is then authorized with
  `EventBridge.authorize_event/3` against the scopes of that post-read check, so a
  read-only caller receives the same metadata-only view live fanout gives it. An
  expired cursor requires snapshot recovery; unavailable runtime reads never
  masquerade as an empty replay or an expired cursor.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.{Connections, EventBridge}
  alias LemonControlPlane.Methods.NativeSessions
  alias LemonCore.AgentRuntime

  @impl true
  def name, do: "sessions.events"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, ctx) when is_map(params) do
    with {:ok, key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, cursor} <- cursor(params["cursor"]),
         {:ok, limit} <- NativeSessions.integer(params, "limit", 50, 1, 100),
         {:ok, _scopes} <- authorize(ctx),
         result <- AgentRuntime.call(:session_event_replay, [key, cursor, limit], :unavailable),
         {:ok, scopes} <- authorize(ctx) do
      project(key, cursor, limit, result, scopes)
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def handle(_, _), do: NativeSessions.invalid("sessionKey and cursor are required")

  defp cursor(%{"version" => version}) when version != 1,
    do: unsupported_version()

  defp cursor(%{"version" => 1, "seq" => seq} = value)
       when map_size(value) == 4 and is_integer(seq) and seq >= 0 do
    with {:ok, _} <- NativeSessions.string(value, "sessionId", 1024),
         {:ok, _} <- NativeSessions.string(value, "streamId", 1024) do
      {:ok, value}
    end
  end

  defp cursor(_), do: NativeSessions.invalid("cursor must be a version 1 session event cursor")

  # Returns the current operator scopes: the registered connection's when the
  # request came over a connection, otherwise the in-process context's.
  defp authorize(%{auth: auth} = ctx) do
    with {:ok, _} <- operator(auth) do
      case ctx do
        %{conn_pid: pid} when is_pid(pid) ->
          matches =
            Enum.filter(Connections.list(), fn {id, info} ->
              info.pid == pid and (not Map.has_key?(ctx, :conn_id) or ctx.conn_id == id)
            end)

          case matches do
            [{_, %{role: :operator, auth: current}}] -> operator(current)
            _ -> forbidden()
          end

        %{conn_pid: _} ->
          forbidden()

        _ ->
          operator(auth)
      end
    end
  end

  defp authorize(_), do: forbidden()

  defp operator(%{role: :operator, scopes: scopes} = auth) when is_list(scopes) do
    with :ok <- Authorize.authorize(auth, name(), scopes()), do: {:ok, scopes}
  end

  defp operator(_), do: forbidden()

  defp project(
         key,
         after_cursor,
         limit,
         {:ok, %{events: entries, cursor: last, has_more: more}},
         scopes
       )
       when is_list(entries) and is_boolean(more) and length(entries) <= limit do
    with {:ok, projected, expected_last} <- entries(entries, after_cursor, scopes, []),
         true <- last == expected_last and (not more or projected != []) do
      {:ok,
       %{
         "status" => "ok",
         "sessionKey" => key,
         "entries" => projected,
         "cursor" => last,
         "hasMore" => more
       }}
    else
      _ -> unavailable()
    end
  end

  defp project(key, _cursor, _limit, {:error, :cursor_expired}, _scopes) do
    {:ok,
     %{
       "status" => "cursor_expired",
       "sessionKey" => key,
       "entries" => [],
       "cursor" => nil,
       "hasMore" => false
     }}
  end

  defp project(_key, _cursor, _limit, {:error, :unsupported_cursor_version}, _scopes),
    do: unsupported_version()

  defp project(_, _, _, _, _), do: unavailable()

  defp entries([], cursor, _scopes, acc), do: {:ok, Enum.reverse(acc), cursor}

  defp entries([%{cursor: next, event_id: id, events: events} | rest], previous, scopes, acc)
       when is_list(events) do
    with {:ok, ^next} <- cursor(next),
         true <- Map.delete(next, "seq") == Map.delete(previous, "seq"),
         true <- next["seq"] == previous["seq"] + 1,
         true <- id == next["streamId"] <> ":" <> Integer.to_string(next["seq"]) do
      projected =
        for event <- events,
            {name, payload} <- [EventBridge.project(event)],
            {name, payload} <- [EventBridge.authorize_event(name, payload, scopes)],
            do: %{"event" => name, "payload" => payload}

      entry = %{"cursor" => next, "eventId" => id, "events" => projected}
      entries(rest, next, scopes, [entry | acc])
    else
      _ -> :invalid
    end
  end

  defp entries(_, _, _, _), do: :invalid

  defp unsupported_version do
    {:error,
     {:invalid_params, "Unsupported session event cursor version",
      %{"reason" => "unsupported_cursor_version"}}}
  end

  defp forbidden,
    do: {:error, {:forbidden, "Current operator read authorization required", nil}}

  defp unavailable,
    do: {:error, {:unavailable, "Session event replay unavailable", nil}}
end

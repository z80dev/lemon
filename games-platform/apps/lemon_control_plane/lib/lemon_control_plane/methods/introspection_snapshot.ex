defmodule LemonControlPlane.Methods.IntrospectionSnapshot do
  @moduledoc """
  Handler for the `introspection.snapshot` method.

  Returns a consolidated snapshot of agents, sessions, channels, and transports.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.{
    AgentDirectoryList,
    ChannelsStatus,
    SessionsActiveList,
    TransportsStatus
  }

  @impl true
  def name, do: "introspection.snapshot"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}

    include_agents? = get_boolean_param(params, "includeAgents", true)
    include_sessions? = get_boolean_param(params, "includeSessions", true)
    include_active_sessions? = get_boolean_param(params, "includeActiveSessions", true)
    include_channels? = get_boolean_param(params, "includeChannels", true)
    include_transports? = get_boolean_param(params, "includeTransports", true)

    agent_id = get_param(params, "agentId")
    route = normalize_route_filter(get_param(params, "route"))
    limit = normalize_limit(get_param(params, "limit"))
    session_limit = normalize_limit(get_param(params, "sessionLimit")) || limit
    active_limit = normalize_limit(get_param(params, "activeLimit")) || session_limit || limit

    {agents, sessions, directory_error} =
      fetch_directory_snapshot(
        include_agents?,
        include_sessions?,
        agent_id,
        route,
        session_limit,
        ctx
      )

    {active_sessions, active_error} =
      fetch_active_sessions(include_active_sessions?, agent_id, route, active_limit, ctx)

    {channels, channels_error} = fetch_channels(include_channels?, ctx)
    {transports, transports_error} = fetch_transports(include_transports?, ctx)

    errors =
      [directory_error, active_error, channels_error, transports_error]
      |> Enum.reject(&is_nil/1)

    {:ok,
     %{
       "generatedAtMs" => System.system_time(:millisecond),
       "includes" => %{
         "agents" => include_agents?,
         "sessions" => include_sessions?,
         "activeSessions" => include_active_sessions?,
         "channels" => include_channels?,
         "transports" => include_transports?
       },
       "filters" => %{
         "agentId" => agent_id,
         "route" => format_route_filter(route),
         "limit" => limit,
         "sessionLimit" => session_limit,
         "activeLimit" => active_limit
       },
       "agents" => agents,
       "sessions" => sessions,
       "activeSessions" => active_sessions,
       "channels" => channels,
       "transports" => transports,
       "runs" => run_counts(),
       "counts" => %{
         "agents" => length(agents),
         "sessions" => length(sessions),
         "activeSessions" => length(active_sessions),
         "channels" => length(channels),
         "transports" => length(transports),
         "enabledTransports" => Enum.count(transports, &(&1["enabled"] == true))
       },
       "errors" => errors
     }}
  end

  defp fetch_directory_snapshot(false, false, _agent_id, _route, _limit, _ctx),
    do: {[], [], nil}

  defp fetch_directory_snapshot(include_agents?, include_sessions?, agent_id, route, limit, ctx) do
    params =
      %{
        "agentId" => agent_id,
        "includeSessions" => include_sessions?,
        "limit" => limit
      }
      |> maybe_put("route", route)
      |> drop_nil_values()

    case AgentDirectoryList.handle(params, ctx) do
      {:ok, payload} ->
        agents = if include_agents?, do: payload["agents"] || [], else: []
        sessions = if include_sessions?, do: payload["sessions"] || [], else: []
        {agents, sessions, nil}

      {:error, reason} ->
        {[], [], format_error("agent.directory.list", reason)}
    end
  end

  defp fetch_active_sessions(false, _agent_id, _route, _limit, _ctx), do: {[], nil}

  defp fetch_active_sessions(true, agent_id, route, limit, ctx) do
    params =
      %{
        "agentId" => agent_id,
        "limit" => limit
      }
      |> maybe_put("route", route)
      |> drop_nil_values()

    case SessionsActiveList.handle(params, ctx) do
      {:ok, payload} -> {payload["sessions"] || [], nil}
      {:error, reason} -> {[], format_error("sessions.active.list", reason)}
    end
  end

  defp fetch_channels(false, _ctx), do: {[], nil}

  defp fetch_channels(true, ctx) do
    {:ok, payload} = ChannelsStatus.handle(%{}, ctx)
    {payload["channels"] || [], nil}
  rescue
    e -> {[], format_error("channels.status", {:internal_error, Exception.message(e)})}
  catch
    :exit, reason -> {[], format_error("channels.status", reason)}
  end

  defp fetch_transports(false, _ctx), do: {[], nil}

  defp fetch_transports(true, ctx) do
    {:ok, payload} = TransportsStatus.handle(%{}, ctx)
    {payload["transports"] || [], nil}
  rescue
    e -> {[], format_error("transports.status", {:internal_error, Exception.message(e)})}
  catch
    :exit, reason -> {[], format_error("transports.status", reason)}
  end

  defp run_counts do
    if Code.ensure_loaded?(LemonRouter.RunOrchestrator) do
      LemonRouter.RunOrchestrator.counts()
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
    else
      %{"active" => 0, "queued" => 0, "completed_today" => 0}
    end
  rescue
    _ -> %{"active" => 0, "queued" => 0, "completed_today" => 0}
  catch
    :exit, _ -> %{"active" => 0, "queued" => 0, "completed_today" => 0}
  end

  defp format_error(component, {code, message, details}) do
    %{
      "component" => component,
      "code" => to_string(code),
      "message" => message,
      "details" => details
    }
    |> drop_nil_values()
  end

  defp format_error(component, {code, message}) do
    %{
      "component" => component,
      "code" => to_string(code),
      "message" => message
    }
  end

  defp format_error(component, %{code: code, message: message, details: details}) do
    %{
      "component" => component,
      "code" => to_string(code),
      "message" => message,
      "details" => details
    }
    |> drop_nil_values()
  end

  defp format_error(component, %{code: code, message: message}) do
    %{
      "component" => component,
      "code" => to_string(code),
      "message" => message
    }
  end

  defp format_error(component, reason) do
    %{
      "component" => component,
      "code" => "unknown",
      "message" => inspect(reason)
    }
  end

  defp normalize_route_filter(route) when is_map(route) do
    %{}
    |> maybe_put(
      :channel_id,
      normalize_optional_binary(route_value(route, :channel_id, "channelId"))
    )
    |> maybe_put(
      :account_id,
      normalize_optional_binary(route_value(route, :account_id, "accountId"))
    )
    |> maybe_put(
      :peer_kind,
      normalize_optional_binary(route_value(route, :peer_kind, "peerKind"))
    )
    |> maybe_put(
      :peer_id,
      normalize_optional_binary(route_value(route, :peer_id, "peerId", :chat_id, "chatId"))
    )
    |> maybe_put(
      :thread_id,
      normalize_optional_binary(route_value(route, :thread_id, "threadId", :topic_id, "topicId"))
    )
  end

  defp normalize_route_filter(_), do: %{}

  defp format_route_filter(route) when is_map(route) do
    %{
      "channelId" => map_get(route, :channel_id),
      "accountId" => map_get(route, :account_id),
      "peerKind" => map_get(route, :peer_kind),
      "peerId" => map_get(route, :peer_id),
      "threadId" => map_get(route, :thread_id)
    }
    |> drop_nil_values()
  end

  defp format_route_filter(_), do: %{}

  defp route_value(route, primary_atom, primary_string) do
    map_get(route, primary_atom) || map_get(route, primary_string)
  end

  defp route_value(route, a1, s1, a2, s2) do
    route_value(route, a1, s1) || map_get(route, a2) || map_get(route, s2)
  end

  defp get_boolean_param(params, key, default) do
    case get_param(params, key) do
      nil -> default
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_), do: nil

  defp normalize_optional_binary(nil), do: nil

  defp normalize_optional_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_binary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_optional_binary()

  defp normalize_optional_binary(value) when is_integer(value),
    do: value |> Integer.to_string() |> normalize_optional_binary()

  defp normalize_optional_binary(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    underscored = Macro.underscore(key)
    Map.get(map, key) || Map.get(map, underscored)
  end

  defp map_get(_, _), do: nil
end

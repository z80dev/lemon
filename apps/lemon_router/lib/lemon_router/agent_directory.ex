defmodule LemonRouter.AgentDirectory do
  @moduledoc """
  Discoverable directory for agent sessions and routing endpoints.

  This module merges:

  - Active sessions from `LemonRouter.SessionRegistry`
  - Durable session metadata from `LemonCore.Store` (`:sessions_index`)

  to provide a "phonebook" for agent/session addressing.
  """

  alias LemonCore.SessionKey

  @registry_select_spec [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]

  @peer_kind_map %{
    "dm" => :dm,
    "group" => :group,
    "channel" => :channel,
    "main" => :main,
    "unknown" => :unknown
  }

  @type route_filter :: %{
          optional(:channel_id) => binary(),
          optional(:account_id) => binary(),
          optional(:peer_kind) => atom(),
          optional(:peer_id) => binary(),
          optional(:thread_id) => binary()
        }

  @type session_entry :: %{
          session_key: binary(),
          agent_id: binary(),
          kind: :main | :channel_peer | :unknown,
          channel_id: binary() | nil,
          account_id: binary() | nil,
          peer_kind: atom() | nil,
          peer_id: binary() | nil,
          thread_id: binary() | nil,
          peer_label: binary() | nil,
          peer_username: binary() | nil,
          topic_name: binary() | nil,
          chat_type: binary() | nil,
          sub_id: binary() | nil,
          created_at_ms: integer() | nil,
          updated_at_ms: integer() | nil,
          active?: boolean(),
          run_id: binary() | nil,
          run_count: non_neg_integer() | nil,
          origin: term()
        }

  @doc """
  List known sessions.

  Options:

  - `:agent_id` - optional agent filter
  - `:route` - optional route filter map (`channel_id`, `account_id`, `peer_kind`, `peer_id`, `thread_id`)
  - `:limit` - optional max rows
  """
  @spec list_sessions(keyword()) :: [session_entry()]
  def list_sessions(opts \\ []) do
    agent_id_filter = normalize_optional_binary(opts[:agent_id])
    route_filter = normalize_route_filter(opts[:route])
    limit = normalize_limit(opts[:limit])

    indexed_sessions()
    |> merge_sessions(active_sessions())
    |> Enum.filter(&matches_agent?(&1, agent_id_filter))
    |> Enum.filter(&matches_route?(&1, route_filter))
    |> sort_sessions()
    |> maybe_take(limit)
  end

  @doc """
  Returns the latest known session for an agent.
  """
  @spec latest_session(binary(), keyword()) :: {:ok, session_entry()} | {:error, :not_found}
  def latest_session(agent_id, opts \\ []) when is_binary(agent_id) and agent_id != "" do
    opts
    |> Keyword.put(:agent_id, agent_id)
    |> list_sessions()
    |> case do
      [session | _] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the latest route-backed session (`kind == :channel_peer`) for an agent.
  """
  @spec latest_route_session(binary(), keyword()) :: {:ok, session_entry()} | {:error, :not_found}
  def latest_route_session(agent_id, opts \\ []) when is_binary(agent_id) and agent_id != "" do
    opts
    |> Keyword.put(:agent_id, agent_id)
    |> list_sessions()
    |> Enum.find(&(&1.kind == :channel_peer))
    |> case do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  List agent directory entries with lightweight session/activity stats.
  """
  @spec list_agents(keyword()) :: [map()]
  def list_agents(_opts \\ []) do
    sessions = list_sessions()
    sessions_by_agent = Enum.group_by(sessions, & &1.agent_id)
    profiles = profile_index()

    agent_ids =
      (Map.keys(sessions_by_agent) ++ Map.keys(profiles))
      |> Enum.uniq()

    agent_ids
    |> Enum.map(fn agent_id ->
      agent_sessions = Map.get(sessions_by_agent, agent_id, [])
      latest = List.first(agent_sessions)
      profile = Map.get(profiles, agent_id, %{})

      %{
        agent_id: agent_id,
        name: map_get(profile, :name) || agent_id,
        description: map_get(profile, :description),
        latest_session_key: latest && latest.session_key,
        latest_updated_at_ms: latest && latest.updated_at_ms,
        active_session_count: Enum.count(agent_sessions, & &1.active?),
        session_count: length(agent_sessions),
        route_count:
          agent_sessions
          |> Enum.filter(&(&1.kind == :channel_peer))
          |> Enum.map(&route_signature/1)
          |> Enum.uniq()
          |> length()
      }
    end)
    |> Enum.sort_by(fn entry -> entry.latest_updated_at_ms || 0 end, :desc)
  end

  @doc """
  List known channel targets for human-friendly routing.

  This is intended for CLI/UI discovery before creating endpoint aliases.
  """
  @spec list_targets(keyword()) :: [map()]
  def list_targets(opts \\ []) do
    route_filter =
      normalize_route_filter(%{
        channel_id: opts[:channel_id],
        account_id: opts[:account_id],
        peer_kind: opts[:peer_kind],
        peer_id: opts[:peer_id],
        thread_id: opts[:thread_id]
      })

    session_stats =
      list_sessions(
        agent_id: normalize_optional_binary(opts[:agent_id]),
        route: route_filter
      )
      |> Enum.filter(&(&1.kind == :channel_peer))
      |> Enum.group_by(&route_signature/1)
      |> Enum.map(fn {signature, sessions} ->
        latest = Enum.max_by(sessions, &(&1.updated_at_ms || 0), fn -> nil end)

        {signature,
         %{
           session_count: length(sessions),
           active_session_count: Enum.count(sessions, & &1.active?),
           agent_ids: sessions |> Enum.map(& &1.agent_id) |> Enum.uniq() |> Enum.sort(),
           latest_session_key: latest && latest.session_key,
           latest_updated_at_ms: latest && latest.updated_at_ms,
           peer_label: latest && latest.peer_label,
           peer_username: latest && latest.peer_username,
           topic_name: latest && latest.topic_name
         }}
      end)
      |> Map.new()

    known_routes =
      known_telegram_targets()
      |> Enum.filter(fn route ->
        matches_route_map?(route, route_filter)
      end)
      |> Enum.map(&{route_signature(&1), &1})
      |> Map.new()

    signatures =
      (Map.keys(session_stats) ++ Map.keys(known_routes))
      |> Enum.uniq()

    signatures
    |> Enum.map(fn signature ->
      route =
        Map.get(known_routes, signature) ||
          route_from_signature(signature)

      stats = Map.get(session_stats, signature, %{})
      peer_label = map_get(route, :peer_label) || map_get(stats, :peer_label)
      peer_username = map_get(route, :peer_username) || map_get(stats, :peer_username)
      topic_name = map_get(route, :topic_name) || map_get(stats, :topic_name)

      latest_updated_at_ms =
        map_get(route, :updated_at_ms) || map_get(stats, :latest_updated_at_ms)

      %{
        channel_id: route.channel_id,
        account_id: route.account_id,
        peer_kind: route.peer_kind,
        peer_id: route.peer_id,
        thread_id: route.thread_id,
        target: render_target(route),
        label: render_target_label(route, peer_label, peer_username, topic_name),
        peer_label: peer_label,
        peer_username: peer_username,
        topic_name: topic_name,
        chat_type: map_get(route, :chat_type),
        chat_id: parse_int(route.peer_id),
        topic_id: parse_int(route.thread_id),
        session_count: map_get(stats, :session_count) || 0,
        active_session_count: map_get(stats, :active_session_count) || 0,
        latest_session_key: map_get(stats, :latest_session_key),
        latest_updated_at_ms: latest_updated_at_ms,
        agent_ids: map_get(stats, :agent_ids) || []
      }
    end)
    |> maybe_filter_targets_by_query(opts[:query])
    |> Enum.sort_by(fn entry -> entry.latest_updated_at_ms || 0 end, :desc)
    |> maybe_take(normalize_limit(opts[:limit]))
  end

  defp route_signature(session) do
    {session.channel_id, session.account_id, session.peer_kind, session.peer_id,
     session.thread_id}
  end

  defp profile_index do
    if Code.ensure_loaded?(LemonRouter.AgentProfiles) and
         is_pid(Process.whereis(LemonRouter.AgentProfiles)) do
      LemonRouter.AgentProfiles.list()
      |> Enum.reduce(%{}, fn profile, acc ->
        id = map_get(profile, :id) || "default"
        Map.put(acc, to_string(id), profile)
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp indexed_sessions do
    LemonCore.Store.list(:sessions_index)
    |> Enum.map(&indexed_session_entry/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp indexed_session_entry({session_key, entry})
       when is_binary(session_key) and is_map(entry) do
    parsed = parse_session(session_key)

    %{
      session_key: session_key,
      agent_id:
        map_get(entry, :agent_id) || parsed_agent_id(parsed) || SessionKey.agent_id(session_key) ||
          "default",
      kind: parsed_kind(parsed),
      channel_id: parsed_field(parsed, :channel_id),
      account_id: parsed_field(parsed, :account_id),
      peer_kind: parsed_field(parsed, :peer_kind),
      peer_id: parsed_field(parsed, :peer_id),
      thread_id: parsed_field(parsed, :thread_id),
      peer_label: normalize_optional_binary(map_get(entry, :peer_label)),
      peer_username: normalize_optional_binary(map_get(entry, :peer_username)),
      topic_name: normalize_optional_binary(map_get(entry, :topic_name)),
      chat_type: normalize_optional_binary(map_get(entry, :chat_type)),
      sub_id: parsed_field(parsed, :sub_id),
      created_at_ms: normalize_int(map_get(entry, :created_at_ms)),
      updated_at_ms: normalize_int(map_get(entry, :updated_at_ms)),
      active?: false,
      run_id: nil,
      run_count: normalize_int(map_get(entry, :run_count)),
      origin: map_get(entry, :origin) || :unknown
    }
  rescue
    _ -> nil
  end

  defp indexed_session_entry(_), do: nil

  defp active_sessions do
    if Code.ensure_loaded?(Registry) and is_pid(Process.whereis(LemonRouter.SessionRegistry)) do
      Registry.select(LemonRouter.SessionRegistry, @registry_select_spec)
      |> Enum.map(&active_session_entry/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp active_session_entry({session_key, _pid, meta}) when is_binary(session_key) do
    parsed = parse_session(session_key)
    run_id = map_get(meta, :run_id)
    started_at_ms = run_started_at_ms(run_id)
    now_ms = System.system_time(:millisecond)

    %{
      session_key: session_key,
      agent_id: parsed_agent_id(parsed) || SessionKey.agent_id(session_key) || "default",
      kind: parsed_kind(parsed),
      channel_id: parsed_field(parsed, :channel_id),
      account_id: parsed_field(parsed, :account_id),
      peer_kind: parsed_field(parsed, :peer_kind),
      peer_id: parsed_field(parsed, :peer_id),
      thread_id: parsed_field(parsed, :thread_id),
      peer_label: nil,
      peer_username: nil,
      topic_name: nil,
      chat_type: nil,
      sub_id: parsed_field(parsed, :sub_id),
      created_at_ms: started_at_ms,
      updated_at_ms: started_at_ms || now_ms,
      active?: true,
      run_id: run_id,
      run_count: nil,
      origin: :active
    }
  rescue
    _ -> nil
  end

  defp active_session_entry(_), do: nil

  defp run_started_at_ms(run_id) when is_binary(run_id) and run_id != "" do
    case LemonCore.Store.get_run(run_id) do
      nil -> nil
      run when is_map(run) -> normalize_int(map_get(run, :started_at))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp run_started_at_ms(_), do: nil

  defp merge_sessions(indexed, active) do
    indexed_map = Map.new(indexed, &{&1.session_key, &1})

    active
    |> Enum.reduce(indexed_map, fn active_entry, acc ->
      Map.update(acc, active_entry.session_key, active_entry, fn indexed_entry ->
        Map.merge(indexed_entry, active_entry, fn
          :created_at_ms, existing, incoming -> existing || incoming
          :updated_at_ms, existing, incoming -> max_timestamp(existing, incoming)
          :run_count, existing, _incoming -> existing
          :origin, existing, _incoming -> existing
          :peer_label, existing, incoming -> incoming || existing
          :peer_username, existing, incoming -> incoming || existing
          :topic_name, existing, incoming -> incoming || existing
          :chat_type, existing, incoming -> incoming || existing
          _key, _existing, incoming -> incoming
        end)
      end)
    end)
    |> Map.values()
  end

  defp max_timestamp(a, b) when is_integer(a) and is_integer(b), do: max(a, b)
  defp max_timestamp(a, _b) when is_integer(a), do: a
  defp max_timestamp(_a, b) when is_integer(b), do: b
  defp max_timestamp(_a, _b), do: nil

  defp sort_sessions(entries) do
    Enum.sort_by(
      entries,
      fn entry ->
        {if(entry.active?, do: 1, else: 0), entry.updated_at_ms || 0, entry.created_at_ms || 0}
      end,
      :desc
    )
  end

  defp maybe_take(entries, nil), do: entries

  defp maybe_take(entries, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(entries, limit)

  defp maybe_take(entries, _), do: entries

  defp matches_agent?(_session, nil), do: true
  defp matches_agent?(session, agent_id), do: session.agent_id == agent_id

  defp matches_route?(_session, filter) when map_size(filter) == 0, do: true

  defp matches_route?(session, filter) do
    Enum.all?(filter, fn
      {:channel_id, value} -> session.channel_id == value
      {:account_id, value} -> session.account_id == value
      {:peer_kind, value} -> session.peer_kind == value
      {:peer_id, value} -> session.peer_id == value
      {:thread_id, value} -> session.thread_id == value
      _ -> true
    end)
  end

  defp matches_route_map?(route, filter) do
    Enum.all?(filter, fn
      {:channel_id, value} -> map_get(route, :channel_id) == value
      {:account_id, value} -> map_get(route, :account_id) == value
      {:peer_kind, value} -> map_get(route, :peer_kind) == value
      {:peer_id, value} -> map_get(route, :peer_id) == value
      {:thread_id, value} -> map_get(route, :thread_id) == value
      _ -> true
    end)
  end

  defp known_telegram_targets do
    LemonCore.Store.list(:telegram_known_targets)
    |> Enum.map(&known_telegram_target_entry/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp known_telegram_target_entry({key, entry}) when is_tuple(key) and is_map(entry) do
    {account_id, chat_id, topic_id} = key

    with account_id when is_binary(account_id) and account_id != "" <-
           normalize_optional_binary(account_id),
         chat_id when is_integer(chat_id) <- parse_int(chat_id) do
      peer_id = Integer.to_string(chat_id)
      thread_id = parse_int(topic_id) && Integer.to_string(parse_int(topic_id))

      peer_kind =
        normalize_peer_kind(map_get(entry, :peer_kind)) || infer_telegram_peer_kind(chat_id)

      %{
        channel_id: "telegram",
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: thread_id,
        peer_label:
          normalize_optional_binary(
            map_get(entry, :chat_title) || map_get(entry, :chat_display_name)
          ),
        peer_username: normalize_optional_binary(map_get(entry, :chat_username)),
        topic_name: normalize_optional_binary(map_get(entry, :topic_name)),
        chat_type: normalize_optional_binary(map_get(entry, :chat_type)),
        updated_at_ms: normalize_int(map_get(entry, :updated_at_ms))
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp known_telegram_target_entry(_), do: nil

  defp render_target(route) when is_map(route) do
    if route.channel_id == "telegram" do
      account_prefix =
        if route.account_id in [nil, "", "default"] do
          ""
        else
          "#{route.account_id}@"
        end

      suffix =
        case normalize_optional_binary(route.thread_id) do
          nil -> ""
          thread_id -> "/#{thread_id}"
        end

      "tg:#{account_prefix}#{route.peer_id}#{suffix}"
    else
      base = "#{route.channel_id}:#{route.account_id}:#{route.peer_kind}:#{route.peer_id}"

      case normalize_optional_binary(route.thread_id) do
        nil -> base
        thread_id -> "#{base}/#{thread_id}"
      end
    end
  end

  defp render_target(_), do: "unknown"

  defp render_target_label(route, peer_label, peer_username, topic_name) do
    base =
      cond do
        is_binary(peer_label) and peer_label != "" ->
          peer_label

        is_binary(peer_username) and peer_username != "" ->
          "@#{peer_username}"

        true ->
          map_get(route, :peer_id) || "unknown"
      end

    case normalize_optional_binary(topic_name) do
      nil -> base
      name -> "#{base} / #{name}"
    end
  end

  defp maybe_filter_targets_by_query(entries, nil), do: entries
  defp maybe_filter_targets_by_query(entries, ""), do: entries

  defp maybe_filter_targets_by_query(entries, query) when is_binary(query) do
    q = String.downcase(String.trim(query))

    if q == "" do
      entries
    else
      Enum.filter(entries, fn entry ->
        haystack =
          [
            entry.label,
            entry.target,
            entry.peer_label,
            entry.peer_username,
            entry.topic_name,
            entry.peer_id
          ]
          |> Enum.filter(&is_binary/1)
          |> Enum.join(" ")
          |> String.downcase()

        String.contains?(haystack, q)
      end)
    end
  end

  defp maybe_filter_targets_by_query(entries, _), do: entries

  defp normalize_route_filter(route) when is_map(route) do
    %{
      channel_id: normalize_optional_binary(map_get(route, :channel_id)),
      account_id: normalize_optional_binary(map_get(route, :account_id)),
      peer_kind: normalize_peer_kind(map_get(route, :peer_kind)),
      peer_id: normalize_optional_binary(map_get(route, :peer_id) || map_get(route, :chat_id)),
      thread_id:
        normalize_optional_binary(map_get(route, :thread_id) || map_get(route, :topic_id))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp normalize_route_filter(_), do: %{}

  defp normalize_peer_kind(nil), do: nil

  defp normalize_peer_kind(kind) when is_atom(kind) do
    if kind in Map.values(@peer_kind_map), do: kind, else: nil
  end

  defp normalize_peer_kind(kind) when is_binary(kind) do
    Map.get(@peer_kind_map, String.downcase(kind))
  end

  defp normalize_peer_kind(_), do: nil

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

  defp normalize_optional_binary(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_optional_binary(_), do: nil

  defp parse_session(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      {:error, _} -> nil
      parsed when is_map(parsed) -> parsed
    end
  rescue
    _ -> nil
  end

  defp parse_session(_), do: nil

  defp parsed_kind(%{kind: kind}) when kind in [:main, :channel_peer], do: kind
  defp parsed_kind(_), do: :unknown

  defp parsed_agent_id(%{agent_id: agent_id}) when is_binary(agent_id), do: agent_id
  defp parsed_agent_id(_), do: nil

  defp parsed_field(%{} = parsed, key), do: Map.get(parsed, key)
  defp parsed_field(_, _), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp route_from_signature({channel_id, account_id, peer_kind, peer_id, thread_id}) do
    %{
      channel_id: channel_id,
      account_id: account_id,
      peer_kind: peer_kind,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end

  defp route_from_signature(_),
    do: %{channel_id: nil, account_id: nil, peer_kind: nil, peer_id: nil, thread_id: nil}

  defp infer_telegram_peer_kind(chat_id) when is_integer(chat_id) and chat_id < 0, do: :group
  defp infer_telegram_peer_kind(_chat_id), do: :dm

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil
end

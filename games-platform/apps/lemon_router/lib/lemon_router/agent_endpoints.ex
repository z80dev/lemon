defmodule LemonRouter.AgentEndpoints do
  @moduledoc """
  Persistent endpoint aliases for agent routing.

  Endpoints map friendly names (for example `"ops-room"`) to a canonical route:

      %{
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :group,
        peer_id: "-100123456",
        thread_id: "42"
      }

  In addition to stored aliases, this module resolves Telegram shorthand targets:

  - `tg:<chat_id>`
  - `tg:<chat_id>/<topic_id>`
  - `tg:<chat_id>#<topic_id>`
  - `telegram:<chat_id>`
  - `telegram:<chat_id>/<topic_id>`
  - optional account prefix: `tg:<account_id>@<chat_id>/<topic_id>`
  """

  alias LemonCore.SessionKey

  @table :agent_endpoints
  @allowed_peer_kinds [:dm, :group, :channel, :unknown]

  @type route :: %{
          channel_id: binary(),
          account_id: binary(),
          peer_kind: :dm | :group | :channel | :unknown,
          peer_id: binary(),
          thread_id: binary() | nil
        }

  @type endpoint :: %{
          id: binary(),
          agent_id: binary(),
          name: binary(),
          description: binary() | nil,
          route: route(),
          target: binary(),
          session_key: binary(),
          created_at_ms: integer(),
          updated_at_ms: integer()
        }

  @type resolve_result :: %{
          route: route(),
          endpoint: endpoint() | nil,
          target: binary()
        }

  @spec list(keyword()) :: [endpoint()]
  def list(opts \\ []) do
    agent_id = normalize_optional_binary(opts[:agent_id])
    limit = normalize_limit(opts[:limit])

    rows =
      LemonCore.Store.list(@table)
      |> Enum.reduce([], fn
        {{entry_agent_id, _name}, entry}, acc when is_binary(entry_agent_id) and is_map(entry) ->
          if is_nil(agent_id) or entry_agent_id == agent_id do
            [normalize_entry(entry_agent_id, entry) | acc]
          else
            acc
          end

        _, acc ->
          acc
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.updated_at_ms, :desc)

    case limit do
      nil -> rows
      n -> Enum.take(rows, n)
    end
  rescue
    _ -> []
  end

  @spec get(binary(), binary()) :: {:ok, endpoint()} | {:error, :not_found}
  def get(agent_id, name)
      when is_binary(agent_id) and agent_id != "" and is_binary(name) and name != "" do
    with {:ok, normalized_name} <- normalize_name(name),
         entry when is_map(entry) <- LemonCore.Store.get(@table, {agent_id, normalized_name}),
         normalized when is_map(normalized) <- normalize_entry(agent_id, entry) do
      {:ok, normalized}
    else
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get(_agent_id, _name), do: {:error, :not_found}

  @spec put(binary(), binary(), term(), keyword()) :: {:ok, endpoint()} | {:error, term()}
  def put(agent_id, name, target, opts \\ [])

  def put(agent_id, name, target, opts)
      when is_binary(agent_id) and agent_id != "" and is_binary(name) and name != "" do
    now = System.system_time(:millisecond)

    with {:ok, normalized_name} <- normalize_name(name),
         {:ok, resolved} <- resolve(agent_id, target, opts),
         {:ok, route} <- normalize_route(resolved.route, opts) do
      existing = LemonCore.Store.get(@table, {agent_id, normalized_name})

      endpoint = %{
        id: map_get(existing, :id) || "endpoint_#{LemonCore.Id.uuid()}",
        agent_id: agent_id,
        name: normalized_name,
        description:
          normalize_optional_binary(opts[:description] || map_get(existing, :description)),
        route: route,
        target: render_target(route),
        session_key: route_session_key(agent_id, route),
        created_at_ms: normalize_int(map_get(existing, :created_at_ms)) || now,
        updated_at_ms: now
      }

      case LemonCore.Store.put(@table, {agent_id, normalized_name}, endpoint) do
        :ok -> {:ok, endpoint}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e -> {:error, e}
  end

  def put(_agent_id, _name, _target, _opts), do: {:error, :invalid_arguments}

  @spec delete(binary(), binary()) :: :ok | {:error, term()}
  def delete(agent_id, name)
      when is_binary(agent_id) and agent_id != "" and is_binary(name) and name != "" do
    with {:ok, normalized_name} <- normalize_name(name) do
      LemonCore.Store.delete(@table, {agent_id, normalized_name})
      :ok
    end
  rescue
    _ -> :ok
  end

  def delete(_agent_id, _name), do: {:error, :invalid_arguments}

  @doc """
  Resolve a target into a canonical route.

  Target can be:
  - endpoint alias name (stored under agent_id)
  - Telegram shorthand string (`tg:...`)
  - route map
  """
  @spec resolve(binary(), term(), keyword()) :: {:ok, resolve_result()} | {:error, term()}
  def resolve(agent_id, target, opts \\ [])

  def resolve(_agent_id, target, opts) when is_map(target) do
    with {:ok, route} <- normalize_route(target, opts) do
      {:ok, %{route: route, endpoint: nil, target: render_target(route)}}
    end
  end

  def resolve(agent_id, target, opts) when is_binary(target) and target != "" do
    target = String.trim(target)

    with {:ok, endpoint} <- maybe_get_endpoint(agent_id, target) do
      {:ok, %{route: endpoint.route, endpoint: endpoint, target: endpoint.name}}
    else
      {:error, :not_found} ->
        with {:ok, route} <- parse_target_string(target, opts),
             {:ok, normalized_route} <- normalize_route(route, opts) do
          {:ok,
           %{route: normalized_route, endpoint: nil, target: render_target(normalized_route)}}
        end

      other ->
        other
    end
  end

  def resolve(_agent_id, nil, _opts), do: {:error, :missing_target}
  def resolve(_agent_id, _target, _opts), do: {:error, :invalid_target}

  @spec route_filter(route()) :: map()
  def route_filter(%{} = route) do
    %{
      channel_id: map_get(route, :channel_id),
      account_id: map_get(route, :account_id),
      peer_kind: map_get(route, :peer_kind),
      peer_id: map_get(route, :peer_id),
      thread_id: map_get(route, :thread_id)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def route_filter(_), do: %{}

  @spec route_session_key(binary(), route()) :: binary()
  def route_session_key(agent_id, route) when is_binary(agent_id) and is_map(route) do
    SessionKey.channel_peer(%{
      agent_id: agent_id,
      channel_id: route.channel_id,
      account_id: route.account_id,
      peer_kind: route.peer_kind,
      peer_id: route.peer_id,
      thread_id: route.thread_id
    })
  end

  @spec route_signature(route()) :: {binary(), binary(), atom(), binary(), binary() | nil}
  def route_signature(%{} = route) do
    {
      map_get(route, :channel_id),
      map_get(route, :account_id),
      map_get(route, :peer_kind),
      map_get(route, :peer_id),
      map_get(route, :thread_id)
    }
  end

  defp maybe_get_endpoint(agent_id, target) do
    case get(agent_id, target) do
      {:ok, endpoint} -> {:ok, endpoint}
      _ -> {:error, :not_found}
    end
  end

  defp normalize_entry(agent_id, entry) when is_binary(agent_id) and is_map(entry) do
    with {:ok, name} <- normalize_name(map_get(entry, :name) || "endpoint"),
         {:ok, route} <- normalize_route(map_get(entry, :route), []) do
      %{
        id: map_get(entry, :id) || "endpoint_#{LemonCore.Id.uuid()}",
        agent_id: agent_id,
        name: name,
        description: normalize_optional_binary(map_get(entry, :description)),
        route: route,
        target: normalize_optional_binary(map_get(entry, :target)) || render_target(route),
        session_key:
          normalize_optional_binary(map_get(entry, :session_key)) ||
            route_session_key(agent_id, route),
        created_at_ms:
          normalize_int(map_get(entry, :created_at_ms)) || System.system_time(:millisecond),
        updated_at_ms:
          normalize_int(map_get(entry, :updated_at_ms)) || System.system_time(:millisecond)
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp normalize_entry(_agent_id, _entry), do: nil

  defp parse_target_string(target, opts) when is_binary(target) do
    with {:ok, parsed} <- parse_telegram_target(target),
         {:ok, route} <- normalize_route(parsed, opts) do
      {:ok, route}
    end
  end

  defp parse_target_string(_target, _opts), do: {:error, :invalid_target}

  defp parse_telegram_target(target) do
    regex = ~r/^(?:tg|telegram):(?:(?<account>[^@\/#]+)@)?(?<chat>-?\d+)(?:[\/#](?<topic>\d+))?$/i

    case Regex.named_captures(regex, target) do
      %{"chat" => chat_id} = captures ->
        account_id = normalize_optional_binary(captures["account"]) || "default"
        thread_id = normalize_optional_binary(captures["topic"])
        peer_kind = infer_telegram_peer_kind(chat_id)

        {:ok,
         %{
           channel_id: "telegram",
           account_id: account_id,
           peer_kind: peer_kind,
           peer_id: chat_id,
           thread_id: thread_id
         }}

      _ ->
        {:error, :invalid_target}
    end
  end

  defp infer_telegram_peer_kind(chat_id) when is_binary(chat_id) do
    case Integer.parse(chat_id) do
      {i, _} when i < 0 -> :group
      {_, _} -> :dm
      :error -> :dm
    end
  end

  defp normalize_route(route, opts) when is_map(route) do
    route = route || %{}

    channel_id =
      normalize_optional_binary(
        map_get(route, :channel_id) || map_get(route, :channelId) ||
          if(is_nil(map_get(route, :chat_id) || map_get(route, :chatId)),
            do: nil,
            else: "telegram"
          )
      )

    peer_id =
      normalize_optional_binary(
        map_get(route, :peer_id) || map_get(route, :peerId) ||
          map_get(route, :chat_id) || map_get(route, :chatId)
      )

    account_id =
      normalize_optional_binary(
        map_get(route, :account_id) || map_get(route, :accountId) || opts[:account_id]
      ) || "default"

    thread_id =
      normalize_optional_binary(
        map_get(route, :thread_id) || map_get(route, :threadId) ||
          map_get(route, :topic_id) || map_get(route, :topicId)
      )

    peer_kind =
      normalize_peer_kind(
        map_get(route, :peer_kind) || map_get(route, :peerKind) || opts[:peer_kind] ||
          infer_default_peer_kind(channel_id, peer_id)
      )

    cond do
      is_nil(channel_id) ->
        {:error, :missing_channel_id}

      is_nil(peer_id) ->
        {:error, :missing_peer_id}

      is_nil(peer_kind) ->
        {:error, :invalid_peer_kind}

      true ->
        {:ok,
         %{
           channel_id: channel_id,
           account_id: account_id,
           peer_kind: peer_kind,
           peer_id: peer_id,
           thread_id: thread_id
         }}
    end
  rescue
    _ -> {:error, :invalid_route}
  end

  defp normalize_route(_route, _opts), do: {:error, :invalid_route}

  defp infer_default_peer_kind("telegram", peer_id), do: infer_telegram_peer_kind(peer_id)
  defp infer_default_peer_kind(_channel_id, _peer_id), do: :dm

  defp normalize_peer_kind(kind) when kind in @allowed_peer_kinds, do: kind

  defp normalize_peer_kind(kind) when is_binary(kind) do
    case String.downcase(String.trim(kind)) do
      "dm" -> :dm
      "group" -> :group
      "channel" -> :channel
      "unknown" -> :unknown
      _ -> nil
    end
  end

  defp normalize_peer_kind(_), do: nil

  defp render_target(route) when is_map(route) do
    if route.channel_id == "telegram" do
      account_prefix =
        if route.account_id in [nil, "", "default"] do
          ""
        else
          "#{route.account_id}@"
        end

      topic_suffix =
        case normalize_optional_binary(route.thread_id) do
          nil -> ""
          thread_id -> "/#{thread_id}"
        end

      "tg:#{account_prefix}#{route.peer_id}#{topic_suffix}"
    else
      base =
        "#{route.channel_id}:#{route.account_id}:#{route.peer_kind}:#{route.peer_id}"

      case normalize_optional_binary(route.thread_id) do
        nil -> base
        thread_id -> "#{base}/#{thread_id}"
      end
    end
  end

  defp render_target(_), do: "unknown"

  defp normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._:-]+/u, "-")
      |> String.trim("-")

    if normalized == "" do
      {:error, :invalid_name}
    else
      {:ok, normalized}
    end
  end

  defp normalize_name(_), do: {:error, :invalid_name}

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

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil
end

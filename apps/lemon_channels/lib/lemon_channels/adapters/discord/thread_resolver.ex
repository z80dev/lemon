defmodule LemonChannels.Adapters.Discord.ThreadResolver do
  @moduledoc """
  The one place that decides whether a Discord channel id is a thread.

  Discord delivers messages and interactions posted in a thread with the
  thread's id as `channel_id`; a Nostrum `%Message{}` carries no parent, while
  an interaction may carry a partial channel. Every inbound path asks this
  module for the location and keys sessions, preferences, trigger mode and
  approvals on the same `{parent_channel_id, thread_id}` pair.

  Answers come from, in order: a channel object the event itself carries,
  the channel cache (fed by gateway channel/thread events, interactions and
  earlier lookups), then a REST read of the channel. A failed read is an
  error, never "not a thread": callers must not route under a guessed key.
  """

  alias LemonCore.Dedupe.Ets

  @table :lemon_channels_discord_channel_kinds
  @thread_types [10, 11, 12]
  @max_entries 50_000
  @location_key :lemon_location

  @type location :: %{channel_id: integer(), thread_id: integer() | nil}

  @doc "Ensure the long-lived channel cache exists."
  @spec init() :: :ok
  def init, do: Ets.init(@table)

  @doc """
  Record a channel object (gateway `CHANNEL_*`/`THREAD_*` payload, an
  interaction's partial channel, or a REST result). Objects without an id and
  a determinable kind are ignored.
  """
  @spec observe(term()) :: :ok
  def observe(channel) when is_map(channel) do
    with id when is_integer(id) <- id(channel, :id),
         {:ok, kind} <- classify(channel) do
      :ok = init()
      name = string(get(channel, :name)) || cached_name(id)
      if :ets.info(@table, :size) >= @max_entries, do: :ets.delete_all_objects(@table)
      true = :ets.insert(@table, {id, kind, name})
    end

    :ok
  end

  def observe(_), do: :ok

  @doc "The cached display name of a channel or thread, if one was observed."
  @spec name(term()) :: String.t() | nil
  def name(channel_id), do: channel_id |> parse() |> cached_name()

  defp cached_name(id) when is_integer(id) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, id) do
      [{^id, _kind, name}] -> name
      _ -> nil
    end
  end

  defp cached_name(_), do: nil

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_), do: nil

  @doc """
  Feed the cache from a gateway event. Cheap (ETS only), so the consumer runs
  it before queueing the event and a thread is known before its messages.
  """
  @spec observe_event(atom(), term()) :: :ok
  def observe_event(name, payload) when name in [:CHANNEL_CREATE, :THREAD_CREATE],
    do: observe(payload)

  def observe_event(name, {_old, new}) when name in [:CHANNEL_UPDATE, :THREAD_UPDATE],
    do: observe(new)

  def observe_event(name, payload) when name in [:CHANNEL_UPDATE, :THREAD_UPDATE],
    do: observe(payload)

  def observe_event(name, payload) when name in [:CHANNEL_DELETE, :THREAD_DELETE],
    do: forget(payload)

  def observe_event(:GUILD_CREATE, guild) when is_map(guild) do
    Enum.each([:channels, :threads], fn key -> observe_all(get(guild, key)) end)
  end

  def observe_event(:THREAD_LIST_SYNC, sync) when is_map(sync),
    do: observe_all(get(sync, :threads))

  def observe_event(_name, _payload), do: :ok

  defp observe_all(channels) when is_map(channels), do: observe_all(Map.values(channels))
  defp observe_all(channels) when is_list(channels), do: Enum.each(channels, &observe/1)
  defp observe_all(_), do: :ok

  @doc "Forget a channel (gateway `CHANNEL_DELETE`/`THREAD_DELETE`)."
  @spec forget(term()) :: :ok
  def forget(channel) do
    case id(channel, :id) do
      id when is_integer(id) ->
        if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, id)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Resolve the location of `channel_id`.

  `hint` is a channel object carried by the event (may be nil or partial).
  DM channels (`guild_id` nil) cannot contain threads and need no lookup.
  """
  @spec resolve(term(), term(), term()) :: {:ok, location()} | {:error, :channel_unresolved}
  def resolve(channel_id, hint \\ nil, guild_id \\ :unknown) do
    channel_id = parse(channel_id)

    cond do
      not is_integer(channel_id) ->
        {:error, :channel_unresolved}

      is_nil(guild_id) ->
        {:ok, %{channel_id: channel_id, thread_id: nil}}

      true ->
        resolve_guild_channel(channel_id, hint)
    end
  end

  @doc """
  Resolve an interaction's location once and stash it on the interaction so
  every handler reads the same answer.
  """
  @spec put_location(map()) :: {:ok, map()} | {:error, :channel_unresolved}
  def put_location(interaction) when is_map(interaction) do
    with {:ok, location} <- locate(interaction) do
      {:ok, Map.put(interaction, @location_key, location)}
    end
  end

  @doc "The location of an interaction: the stashed answer, else a fresh resolution."
  @spec locate(map()) :: {:ok, location()} | {:error, :channel_unresolved}
  def locate(interaction) when is_map(interaction) do
    case get(interaction, @location_key) do
      %{channel_id: _, thread_id: _} = location ->
        {:ok, location}

      _ ->
        resolve(
          get(interaction, :channel_id),
          get(interaction, :channel),
          parse(get(interaction, :guild_id))
        )
    end
  end

  @doc "The stashed location of an interaction that went through `put_location/1`."
  @spec location!(map()) :: location()
  def location!(interaction), do: Map.fetch!(interaction, @location_key)

  @doc "Attach an already-resolved location (text commands acting like an interaction)."
  @spec with_location(map(), location()) :: map()
  def with_location(map, %{channel_id: _, thread_id: _} = location),
    do: Map.put(map, @location_key, location)

  @doc "The interaction as Discord sent it, without the stashed location."
  @spec without_location(map()) :: map()
  def without_location(interaction), do: Map.delete(interaction, @location_key)

  defp resolve_guild_channel(channel_id, hint) do
    with :miss <- from_hint(channel_id, hint),
         :miss <- from_cache(channel_id) do
      from_api(channel_id)
    end
  end

  defp from_hint(channel_id, hint) when is_map(hint) do
    hint = if id(hint, :id), do: hint, else: Map.put(hint, :id, channel_id)

    case {id(hint, :id), classify(hint)} do
      {^channel_id, {:ok, kind}} ->
        observe(hint)
        {:ok, location(channel_id, kind)}

      _ ->
        :miss
    end
  end

  defp from_hint(_channel_id, _hint), do: :miss

  defp from_cache(channel_id) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, channel_id) do
      [{^channel_id, kind, _name}] -> {:ok, location(channel_id, kind)}
      _ -> :miss
    end
  end

  defp from_api(channel_id) do
    case fetch(channel_id) do
      {:ok, channel} when is_map(channel) ->
        case classify(channel) do
          {:ok, kind} ->
            observe(Map.put(channel, :id, channel_id))
            {:ok, location(channel_id, kind)}

          :error ->
            {:error, :channel_unresolved}
        end

      _ ->
        {:error, :channel_unresolved}
    end
  rescue
    _ -> {:error, :channel_unresolved}
  catch
    :exit, _ -> {:error, :channel_unresolved}
  end

  defp fetch(channel_id) do
    case Application.get_env(:lemon_channels, :discord_channel_fetcher) do
      fetcher when is_function(fetcher, 1) -> fetcher.(channel_id)
      _ -> Nostrum.Api.Channel.get(channel_id)
    end
  end

  defp location(channel_id, :channel), do: %{channel_id: channel_id, thread_id: nil}

  defp location(thread_id, {:thread, parent_id}),
    do: %{channel_id: parent_id, thread_id: thread_id}

  # A thread is only usable with its parent; a thread-typed object without a
  # parent is not an answer.
  defp classify(channel) do
    type = parse(get(channel, :type))
    parent_id = id(channel, :parent_id)
    thread? = type in @thread_types or is_map(get(channel, :thread_metadata))

    cond do
      thread? and is_integer(parent_id) -> {:ok, {:thread, parent_id}}
      thread? -> :error
      is_integer(type) -> {:ok, :channel}
      true -> :error
    end
  end

  defp id(map, key), do: map |> get(key) |> parse()

  defp get(%_{} = struct, key), do: struct |> Map.from_struct() |> get(key)
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_, _), do: nil

  defp parse(value) when is_integer(value), do: value

  defp parse(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse(_), do: nil
end

defmodule CodingAgent.Tools.WebCache do
  @moduledoc false

  @default_cache_max_entries 100
  @default_persistent_cache_enabled true
  @cache_path_env "LEMON_WEB_CACHE_PATH"
  @cache_enabled_env "LEMON_WEB_CACHE_PERSISTENT"
  @cache_max_entries_env "LEMON_WEB_CACHE_MAX_ENTRIES"
  @state_table :coding_agent_web_cache_state

  @spec resolve_timeout_seconds(term(), pos_integer()) :: pos_integer()
  def resolve_timeout_seconds(value, fallback) do
    value
    |> normalize_number()
    |> case do
      nil -> fallback
      number -> number
    end
    |> floor()
    |> max(1)
  end

  @spec resolve_cache_ttl_ms(term(), number()) :: non_neg_integer()
  def resolve_cache_ttl_ms(value, fallback_minutes) do
    minutes =
      value
      |> normalize_number()
      |> case do
        nil -> fallback_minutes
        number -> number
      end
      |> max(0)

    round(minutes * 60_000)
  end

  @spec normalize_cache_key(String.t()) :: String.t()
  def normalize_cache_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  @spec default_cache_dir() :: String.t()
  def default_cache_dir do
    home =
      System.user_home() ||
        System.get_env("HOME") ||
        "."

    Path.expand(Path.join([home, ".lemon", "cache", "web_tools"]))
  end

  @spec resolve_cache_dir(term()) :: String.t()
  def resolve_cache_dir(value) do
    value =
      normalize_optional_string(System.get_env(@cache_path_env)) ||
        normalize_optional_string(value) ||
        default_cache_dir()

    value
    |> expand_home_path()
    |> Path.expand()
  end

  @spec resolve_cache_max_entries(term(), pos_integer()) :: pos_integer()
  def resolve_cache_max_entries(value, fallback) do
    value
    |> normalize_number()
    |> case do
      nil -> fallback
      number -> number
    end
    |> floor()
    |> max(1)
  end

  @spec read_cache(atom(), String.t(), keyword() | map()) :: {:hit, term()} | :miss
  def read_cache(table, key, opts \\ []) when is_atom(table) and is_binary(key) do
    cache_opts = normalize_cache_opts(opts)
    _ = ensure_table(table)
    maybe_load_persistent_table(table, cache_opts)

    now = now_ms()

    case :ets.lookup(table, key) do
      [{^key, value, expires_at, _inserted_at}] when now <= expires_at ->
        {:hit, value}

      [{^key, _value, _expires_at, _inserted_at}] ->
        :ets.delete(table, key)
        :miss

      _ ->
        :miss
    end
  end

  @spec write_cache(atom(), String.t(), term(), integer(), pos_integer(), keyword() | map()) ::
          :ok
  def write_cache(
        table,
        key,
        value,
        ttl_ms,
        max_entries \\ @default_cache_max_entries,
        opts \\ []
      )
      when is_atom(table) and is_binary(key) and is_integer(ttl_ms) do
    if ttl_ms <= 0 do
      :ok
    else
      cache_opts =
        opts
        |> normalize_cache_opts(max_entries)

      _ = ensure_table(table)
      maybe_load_persistent_table(table, cache_opts)

      now = now_ms()
      evict_expired_entries(table, now)
      evict_if_needed(table, max(cache_opts.max_entries - 1, 0))
      :ets.insert(table, {key, value, now + ttl_ms, now})

      if cache_opts.persistent do
        persist_table(table, cache_opts)
      end

      :ok
    end
  end

  @spec clear_cache(atom(), keyword() | map()) :: :ok
  def clear_cache(table, opts \\ []) when is_atom(table) do
    _ = ensure_table(table)
    :ets.delete_all_objects(table)
    clear_persistent_files(table, normalize_cache_opts(opts))
    clear_loaded_state(table)
    :ok
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError ->
            # Another process created the table first.
            :ets.whereis(table)
        end

      table_id ->
        table_id
    end
  end

  defp maybe_load_persistent_table(_table, %{persistent: false}), do: :ok

  defp maybe_load_persistent_table(table, cache_opts) do
    ensure_state_table()

    table_id = :ets.whereis(table)
    loaded_key = {:loaded, table, cache_opts.cache_dir}

    case :ets.lookup(@state_table, loaded_key) do
      [{^loaded_key, ^table_id}] ->
        :ok

      _ ->
        table_id = :ets.whereis(table)

        case :ets.lookup(@state_table, loaded_key) do
          [{^loaded_key, ^table_id}] ->
            :ok

          _ ->
            maybe_reset_for_cache_dir_change(table, cache_opts.cache_dir)
            load_table_from_disk(table, cache_opts)
            :ets.insert(@state_table, {loaded_key, table_id})
            :ets.insert(@state_table, {{:active_dir, table}, cache_opts.cache_dir})
            :ok
        end
    end
  end

  defp maybe_reset_for_cache_dir_change(table, cache_dir) do
    case :ets.lookup(@state_table, {:active_dir, table}) do
      [{{:active_dir, ^table}, ^cache_dir}] ->
        :ok

      [{{:active_dir, ^table}, _other_dir}] ->
        :ets.delete_all_objects(table)

      _ ->
        :ok
    end
  end

  defp load_table_from_disk(table, cache_opts) do
    now = now_ms()

    cache_opts
    |> cache_file_path(table)
    |> load_entries()
    |> Enum.filter(fn %{expires_at: expires_at} -> expires_at > now end)
    |> Enum.sort_by(& &1.inserted_at, :desc)
    |> Enum.uniq_by(& &1.key)
    |> Enum.take(cache_opts.max_entries)
    |> Enum.reverse()
    |> Enum.each(fn %{key: key, value: value, expires_at: expires_at, inserted_at: inserted_at} ->
      :ets.insert(table, {key, value, expires_at, inserted_at})
    end)
  end

  defp persist_table(table, cache_opts) do
    now = now_ms()
    evict_expired_entries(table, now)
    evict_if_needed(table, cache_opts.max_entries)

    entries =
      :ets.tab2list(table)
      |> Enum.map(fn {key, value, expires_at, inserted_at} ->
        %{
          key: key,
          value: value,
          expires_at: expires_at,
          inserted_at: inserted_at
        }
      end)
      |> Enum.sort_by(& &1.inserted_at, :desc)
      |> Enum.take(cache_opts.max_entries)

    path = cache_file_path(cache_opts, table)

    cond do
      entries == [] ->
        _ = File.rm(path)
        :ok

      true ->
        payload = %{
          "version" => 1,
          "entries" =>
            Enum.map(entries, fn entry ->
              %{
                "key" => entry.key,
                "value" => entry.value,
                "expires_at" => entry.expires_at,
                "inserted_at" => entry.inserted_at
              }
            end)
        }

        with :ok <- File.mkdir_p(Path.dirname(path)),
             {:ok, encoded} <- Jason.encode(payload),
             :ok <- atomic_write(path, encoded) do
          :ok
        else
          _ -> :ok
        end
    end
  end

  defp clear_persistent_files(table, cache_opts) do
    ensure_state_table()

    dirs =
      known_cache_dirs_for_table(table)
      |> MapSet.new()
      |> MapSet.put(cache_opts.cache_dir)
      |> MapSet.put(resolve_cache_dir(nil))
      |> MapSet.to_list()

    Enum.each(dirs, fn dir ->
      _ = File.rm(cache_file_path(%{cache_dir: dir}, table))
    end)
  end

  defp clear_loaded_state(table) do
    ensure_state_table()
    :ets.match_delete(@state_table, {{:loaded, table, :_}, :_})
    :ets.delete(@state_table, {:active_dir, table})
  end

  defp known_cache_dirs_for_table(table) do
    ensure_state_table()

    @state_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:loaded, ^table, cache_dir}, _table_id} -> [cache_dir]
      {{:active_dir, ^table}, cache_dir} -> [cache_dir]
      _ -> []
    end)
  end

  defp load_entries(path) do
    with true <- File.exists?(path),
         {:ok, raw} <- File.read(path),
         {:ok, decoded} <- Jason.decode(raw),
         entries when is_list(entries) <- Map.get(decoded, "entries") do
      entries
      |> Enum.map(&normalize_entry/1)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    key = Map.get(entry, "key")
    expires_at = parse_integer(Map.get(entry, "expires_at"))
    inserted_at = parse_integer(Map.get(entry, "inserted_at"))

    cond do
      not is_binary(key) ->
        nil

      is_nil(expires_at) or is_nil(inserted_at) ->
        nil

      true ->
        %{
          key: key,
          value: Map.get(entry, "value"),
          expires_at: expires_at,
          inserted_at: inserted_at
        }
    end
  end

  defp normalize_entry(_), do: nil

  defp atomic_write(path, content) do
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp ensure_state_table do
    case :ets.whereis(@state_table) do
      :undefined ->
        try do
          :ets.new(@state_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ets.whereis(@state_table)
        end

      table_id ->
        table_id
    end
  end

  defp evict_expired_entries(table, now) do
    :ets.foldl(
      fn
        {key, _value, expires_at, _inserted_at}, :ok when expires_at <= now ->
          :ets.delete(table, key)
          :ok

        _entry, :ok ->
          :ok
      end,
      :ok,
      table
    )
  end

  defp evict_if_needed(table, max_entries) do
    size = :ets.info(table, :size) || 0

    if size > max_entries do
      case oldest_key(table) do
        nil ->
          :ok

        key ->
          :ets.delete(table, key)
          evict_if_needed(table, max_entries)
      end
    else
      :ok
    end
  end

  defp oldest_key(table) do
    :ets.foldl(
      fn
        {key, _value, _expires_at, inserted_at}, nil ->
          {key, inserted_at}

        {key, _value, _expires_at, inserted_at}, {oldest_key, oldest_inserted_at} ->
          if inserted_at < oldest_inserted_at do
            {key, inserted_at}
          else
            {oldest_key, oldest_inserted_at}
          end
      end,
      nil,
      table
    )
    |> case do
      nil -> nil
      {key, _} -> key
    end
  end

  defp cache_file_path(%{cache_dir: cache_dir}, table) do
    Path.join(cache_dir, "#{Atom.to_string(table)}.json")
  end

  defp normalize_cache_opts(opts, fallback_max_entries \\ @default_cache_max_entries) do
    opts_map = ensure_opts_map(opts)
    env_persistent = normalize_optional_string(System.get_env(@cache_enabled_env))
    env_max_entries = normalize_optional_string(System.get_env(@cache_max_entries_env))

    persistent =
      cond do
        is_binary(env_persistent) ->
          truthy?(env_persistent, @default_persistent_cache_enabled)

        true ->
          case get_opt(opts_map, :persistent) do
            {:ok, value} ->
              truthy?(value, @default_persistent_cache_enabled)

            :error ->
              @default_persistent_cache_enabled
          end
      end

    cache_dir =
      opts_map
      |> get_opt_value(:cache_dir)
      |> case do
        nil -> get_opt_value(opts_map, :path)
        value -> value
      end
      |> resolve_cache_dir()

    max_entries =
      opts_map
      |> get_opt_value(:max_entries)
      |> case do
        _ when is_binary(env_max_entries) -> env_max_entries
        nil -> nil
        value -> value
      end
      |> resolve_cache_max_entries(fallback_max_entries)

    %{
      persistent: persistent,
      cache_dir: cache_dir,
      max_entries: max_entries
    }
  end

  defp ensure_opts_map(opts) when is_map(opts), do: opts

  defp ensure_opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp ensure_opts_map(_), do: %{}

  defp get_opt(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(map, to_string(key))
    end
  end

  defp get_opt_value(map, key) do
    case get_opt(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp truthy?(value, default) when value in [nil, ""], do: default
  defp truthy?(value, _default) when value in [false, "false", "0", 0], do: false
  defp truthy?(_value, _default), do: true

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_float(value) do
    value
    |> floor()
    |> max(0)
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp normalize_number(value) when is_number(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp expand_home_path(path) when is_binary(path) do
    if String.starts_with?(path, "~") do
      home =
        System.user_home() ||
          System.get_env("HOME") ||
          ""

      String.replace_prefix(path, "~", home)
    else
      path
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end

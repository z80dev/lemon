defmodule CodingAgent.Tools.WebCache do
  @moduledoc false

  @default_cache_max_entries 100

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

  @spec read_cache(atom(), String.t()) :: {:hit, term()} | :miss
  def read_cache(table, key) when is_atom(table) and is_binary(key) do
    ensure_table(table)
    now = System.monotonic_time(:millisecond)

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

  @spec write_cache(atom(), String.t(), term(), integer(), pos_integer()) :: :ok
  def write_cache(table, key, value, ttl_ms, max_entries \\ @default_cache_max_entries)
      when is_atom(table) and is_binary(key) and is_integer(ttl_ms) do
    if ttl_ms <= 0 do
      :ok
    else
      ensure_table(table)
      evict_if_needed(table, max_entries)

      now = System.monotonic_time(:millisecond)
      :ets.insert(table, {key, value, now + ttl_ms, now})
      :ok
    end
  end

  defp ensure_table(table) do
    case :ets.whereis(table) do
      :undefined ->
        try do
          :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
          :ok
        rescue
          ArgumentError ->
            # Another process created the table first.
            :ok
        end

      _ ->
        :ok
    end
  end

  defp evict_if_needed(table, max_entries) do
    size = :ets.info(table, :size) || 0

    if size >= max_entries do
      case oldest_key(table) do
        nil -> :ok
        key -> :ets.delete(table, key)
      end
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

  defp normalize_number(value) when is_number(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_number(_), do: nil
end

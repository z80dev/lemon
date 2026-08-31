defmodule LemonCore.SessionMetadataStore do
  @moduledoc """
  Typed persistence for operator-managed session metadata.

  Conversation content and run history continue to belong to
  `LemonCore.RunStore`. This store contains only lifecycle annotations that do
  not naturally belong in a run record: an optional title plus pin/archive
  state.
  """

  alias LemonCore.Store

  @table :session_metadata_v1
  @max_patch_attempts 5

  @type metadata :: %{
          session_key: String.t(),
          title: String.t() | nil,
          pinned: boolean(),
          archived: boolean(),
          created_at_ms: integer(),
          updated_at_ms: integer()
        }

  @doc "Fetch lifecycle metadata, returning defaults when none has been stored."
  @spec get(String.t()) :: metadata()
  def get(session_key) when is_binary(session_key) do
    session_key
    |> stored()
    |> normalize(session_key)
  end

  @doc "Fetch stored lifecycle metadata, returning `nil` when no annotation exists."
  @spec fetch(String.t()) :: metadata() | nil
  def fetch(session_key) when is_binary(session_key) do
    case stored(session_key) do
      nil -> nil
      value -> normalize(value, session_key)
    end
  end

  @doc "List stored metadata records. Sessions without annotations are omitted."
  @spec list() :: [{String.t(), metadata()}]
  def list do
    Store.list(@table)
    |> Enum.flat_map(fn
      {session_key, value} when is_binary(session_key) ->
        [{session_key, normalize(value, session_key)}]

      _other ->
        []
    end)
  end

  @doc "Atomically merge validated lifecycle fields into one session record."
  @spec patch(String.t(), map()) :: {:ok, metadata()} | {:error, term()}
  def patch(session_key, attrs) when is_binary(session_key) and is_map(attrs) do
    with {:ok, patch} <- normalize_patch(attrs) do
      do_patch(session_key, patch, @max_patch_attempts)
    end
  end

  @doc "Delete lifecycle metadata for a session."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(session_key) when is_binary(session_key), do: Store.delete(@table, session_key)

  @doc false
  @spec restore(metadata()) :: :ok | {:error, term()}
  def restore(%{session_key: session_key} = metadata) when is_binary(session_key) do
    Store.put(@table, session_key, normalize(metadata, session_key))
  end

  defp do_patch(_session_key, _patch, 0), do: {:error, :concurrent_update}

  defp do_patch(session_key, patch, attempts) do
    existing = stored(session_key)
    now = System.system_time(:millisecond)

    updated =
      existing
      |> normalize(session_key)
      |> Map.merge(patch)
      |> Map.put(:updated_at_ms, now)

    case Store.compare_and_swap(@table, session_key, existing, updated) do
      :ok -> {:ok, updated}
      {:error, :mismatch} -> do_patch(session_key, patch, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp stored(session_key), do: Store.get(@table, session_key)

  defp normalize(value, session_key) do
    value = if is_map(value), do: value, else: %{}
    now = System.system_time(:millisecond)

    %{
      session_key: session_key,
      title: normalize_title(read(value, :title)),
      pinned: read(value, :pinned) == true,
      archived: read(value, :archived) == true,
      created_at_ms: integer_or(read(value, :created_at_ms), now),
      updated_at_ms: integer_or(read(value, :updated_at_ms), now)
    }
  end

  defp normalize_patch(attrs) do
    Enum.reduce_while([:title, :pinned, :archived], {:ok, %{}}, fn field, {:ok, acc} ->
      case fetch(attrs, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_patch_value(field, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, patch} when map_size(patch) == 0 -> {:error, :empty_patch}
      result -> result
    end
  end

  defp normalize_patch_value(:title, nil), do: {:ok, nil}

  defp normalize_patch_value(:title, title) when is_binary(title) do
    title = String.trim(title)

    cond do
      title == "" -> {:ok, nil}
      String.length(title) > 160 -> {:error, {:invalid_title, :too_long}}
      true -> {:ok, title}
    end
  end

  defp normalize_patch_value(:title, _value), do: {:error, {:invalid_title, :not_a_string}}

  defp normalize_patch_value(field, value)
       when field in [:pinned, :archived] and is_boolean(value), do: {:ok, value}

  defp normalize_patch_value(field, _value), do: {:error, {:invalid_boolean, field}}

  defp normalize_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_title(_title), do: nil

  defp integer_or(value, _default) when is_integer(value), do: value
  defp integer_or(_value, default), do: default

  defp read(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp read(_map, _key), do: nil

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end
end

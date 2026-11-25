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
          required(:session_key) => String.t(),
          required(:title) => String.t() | nil,
          required(:pinned) => boolean(),
          required(:archived) => boolean(),
          required(:created_at_ms) => integer(),
          required(:updated_at_ms) => integer(),
          optional(:acp) => map()
        }

  @doc "Fetch lifecycle metadata, returning defaults when none has been stored."
  @spec get(String.t()) :: metadata()
  def get(session_key) when is_binary(session_key) do
    session_key
    |> stored()
    |> normalize(session_key)
  end

  @doc """
  Fetch stored lifecycle metadata: `{:ok, nil}` only when the Store confirms no
  annotation exists, `{:error, :store_unavailable}` when it cannot answer.
  """
  @spec fetch(String.t()) :: {:ok, metadata() | nil} | {:error, :store_unavailable}
  def fetch(session_key) when is_binary(session_key) do
    case Store.fetch(@table, session_key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, normalize(value, session_key)}
      {:error, _reason} = error -> error
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

  @doc "Fetch stored ACP session metadata for `session_key`, failing closed on store error."
  @spec fetch_acp(String.t()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_acp(session_key) when is_binary(session_key) do
    case fetch(session_key) do
      {:ok, %{acp: %{} = acp}} -> {:ok, acp}
      {:ok, _} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch stored ACP session metadata by ACP `session_id`, failing closed on store error."
  @spec fetch_acp_by_id(String.t()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_acp_by_id(session_id) when is_binary(session_id) do
    with {:ok, entries} <- list_acp() do
      {:ok, Enum.find_value(entries, fn {id, acp} -> if id == session_id, do: acp end)}
    end
  end

  @doc """
  List stored ACP session metadata records as `[{session_id, acp}]`, failing
  closed: an unreadable store is `{:error, :store_unavailable}`, never `[]`.
  """
  @spec list_acp() :: {:ok, [{String.t(), map()}]} | {:error, :store_unavailable}
  def list_acp do
    case Store.fetch_all(@table) do
      {:ok, entries} ->
        {:ok,
         Enum.flat_map(entries, fn
           {session_key, value} when is_binary(session_key) ->
             case normalize(value, session_key) do
               %{acp: %{session_id: session_id} = acp} when is_binary(session_id) ->
                 [{session_id, acp}]

               _ ->
                 []
             end

           _other ->
             []
         end)}

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  @doc "Atomically store ACP session metadata on the canonical `session_key` record."
  @spec put_acp(String.t(), map()) :: :ok | {:error, term()}
  def put_acp(session_key, acp_attrs) when is_binary(session_key) and is_map(acp_attrs) do
    case normalize_acp(acp_attrs) do
      %{} = acp -> do_put_acp(session_key, acp, @max_patch_attempts)
      nil -> {:error, :invalid_acp_metadata}
    end
  end

  @doc "Atomically clear transient run pointers from ACP metadata if present."
  @spec clear_acp_run_state(String.t()) :: :ok | {:error, term()}
  def clear_acp_run_state(session_key) when is_binary(session_key) do
    do_clear_acp_run_state(session_key, @max_patch_attempts)
  end

  @doc "Delete lifecycle metadata for a session."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(session_key) when is_binary(session_key), do: Store.delete(@table, session_key)

  @doc false
  @spec restore(metadata()) :: :ok | {:error, term()}
  def restore(%{session_key: session_key} = metadata) when is_binary(session_key) do
    Store.put(@table, session_key, normalize(metadata, session_key))
  end

  defp do_put_acp(_session_key, _acp, 0), do: {:error, :concurrent_update}

  defp do_put_acp(session_key, acp, attempts) do
    with {:ok, existing} <- Store.fetch(@table, session_key) do
      now = System.system_time(:millisecond)

      updated =
        existing
        |> normalize(session_key)
        |> Map.put(:acp, acp)
        |> Map.put(:updated_at_ms, now)

      case Store.compare_and_swap(@table, session_key, existing, updated) do
        :ok -> :ok
        {:error, :mismatch} -> do_put_acp(session_key, acp, attempts - 1)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_clear_acp_run_state(_session_key, 0), do: {:error, :concurrent_update}

  defp do_clear_acp_run_state(session_key, attempts) do
    with {:ok, existing} <- Store.fetch(@table, session_key) do
      case existing && normalize(existing, session_key) do
        %{acp: %{} = acp} = current ->
          cleared =
            acp
            |> Map.put(:last_run_id, nil)
            |> Map.delete(:cancelled_run_id)

          if cleared == acp do
            :ok
          else
            updated =
              current
              |> Map.put(:acp, cleared)
              |> Map.put(:updated_at_ms, System.system_time(:millisecond))

            case Store.compare_and_swap(@table, session_key, existing, updated) do
              :ok -> :ok
              {:error, :mismatch} -> do_clear_acp_run_state(session_key, attempts - 1)
              {:error, reason} -> {:error, reason}
            end
          end

        _ ->
          :ok
      end
    end
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

    base = %{
      session_key: session_key,
      title: normalize_title(read(value, :title)),
      pinned: read(value, :pinned) == true,
      archived: read(value, :archived) == true,
      created_at_ms: integer_or(read(value, :created_at_ms), now),
      updated_at_ms: integer_or(read(value, :updated_at_ms), now)
    }

    case normalize_acp(read(value, :acp)) do
      nil -> base
      acp -> Map.put(base, :acp, acp)
    end
  end

  defp normalize_acp(%{} = acp) do
    # Drop legacy fields (`:mode`, `:native_resume`): plan mode belongs to the
    # native journal and resume state belongs to ChatStateStore / SessionLifecycle.
    acp
    |> Map.drop([:mode, "mode", :native_resume, "native_resume"])
    |> case do
      map when map_size(map) > 0 -> map
      _ -> nil
    end
  end

  defp normalize_acp(_other), do: nil

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

  defp fetch(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end
end

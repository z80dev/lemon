defmodule LemonCore.A2AStore do
  @moduledoc """
  Typed persistent storage for A2A peer contexts, tasks, and messages.

  Remote context identifiers are never used as Lemon session keys. Callers
  store an independently-derived private session key in the context record.

  Outbound contexts, their default pointers and outbound task records belong to
  one `{agent_id, session_key}` owner. Owned reads return `nil` for any record
  created for another owner, and for legacy records that predate ownership.
  """

  alias LemonCore.{Id, Store}

  @contexts :a2a_contexts
  @tasks :a2a_tasks
  @outbound_tasks :a2a_outbound_tasks
  @messages :a2a_messages
  @defaults :a2a_session_default_contexts
  @max_list 1_000

  @type direction :: :inbound | :outbound
  @type owner :: {agent_id :: binary(), session_key :: binary()}

  defguardp owner?(agent_id, session_key)
            when is_binary(agent_id) and agent_id != "" and is_binary(session_key) and
                   session_key != ""

  @spec create_context(direction(), binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_context(direction, peer_id, attrs \\ %{}, opts \\ [])
      when direction in [:inbound, :outbound] and is_binary(peer_id) and is_map(attrs) do
    context_id = Map.get(attrs, :context_id) || Map.get(attrs, "context_id") || Id.uuid7()
    now = now_ms()

    context = %{
      id: context_id,
      direction: direction,
      peer_id: peer_id,
      session_key: Map.get(attrs, :session_key) || Map.get(attrs, "session_key"),
      agent_id: Map.get(attrs, :agent_id) || Map.get(attrs, "agent_id") || "default",
      turn_count: Map.get(attrs, :turn_count) || Map.get(attrs, "turn_count") || 0,
      created_at_ms: now,
      updated_at_ms: now
    }

    case Store.put_new(
           store(opts),
           @contexts,
           context_key(direction, peer_id, context_id),
           context
         ) do
      :ok -> {:ok, context}
      {:error, :exists} -> {:ok, get_context(direction, peer_id, context_id, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec get_context(direction(), binary(), binary(), keyword()) :: map() | nil
  def get_context(direction, peer_id, context_id, opts \\ []) do
    Store.get(store(opts), @contexts, context_key(direction, peer_id, context_id))
  end

  @spec ensure_context(direction(), binary(), binary(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_context(direction, peer_id, context_id, attrs \\ %{}, opts \\ []) do
    case get_context(direction, peer_id, context_id, opts) do
      nil -> create_context(direction, peer_id, Map.put(attrs, :context_id, context_id), opts)
      context -> {:ok, context}
    end
  end

  @doc """
  Creates a fresh outbound context owned by `owner` and selects it as that
  owner's default conversation with `peer_id`.
  """
  @spec new_owned_context(binary(), owner(), keyword()) :: {:ok, map()} | {:error, term()}
  def new_owned_context(peer_id, {agent_id, session_key} = owner, opts \\ [])
      when is_binary(peer_id) and owner?(agent_id, session_key) do
    attrs = %{agent_id: agent_id, session_key: session_key}

    with {:ok, %{agent_id: ^agent_id, session_key: ^session_key} = context} <-
           create_context(:outbound, peer_id, attrs, opts),
         :ok <- Store.put(store(opts), @defaults, default_key(peer_id, owner), context.id) do
      {:ok, context}
    else
      {:ok, _foreign} -> {:error, :foreign_context}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns an outbound context only when it was created for `owner`."
  @spec owned_context(binary(), owner(), binary(), keyword()) :: map() | nil
  def owned_context(peer_id, {agent_id, session_key}, context_id, opts \\ [])
      when is_binary(peer_id) and owner?(agent_id, session_key) and is_binary(context_id) do
    case get_context(:outbound, peer_id, context_id, opts) do
      %{agent_id: ^agent_id, session_key: ^session_key} = context -> context
      _ -> nil
    end
  end

  @doc "Returns `owner`'s default outbound context with `peer_id`, if any."
  @spec default_context(binary(), owner(), keyword()) :: map() | nil
  def default_context(peer_id, {agent_id, session_key} = owner, opts \\ [])
      when is_binary(peer_id) and owner?(agent_id, session_key) do
    case Store.get(store(opts), @defaults, default_key(peer_id, owner)) do
      context_id when is_binary(context_id) -> owned_context(peer_id, owner, context_id, opts)
      _ -> nil
    end
  end

  @spec increment_turn(direction(), binary(), binary(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def increment_turn(direction, peer_id, context_id, opts \\ []) do
    key = context_key(direction, peer_id, context_id)
    server = store(opts)

    case Store.get(server, @contexts, key) do
      nil ->
        {:error, :not_found}

      current ->
        replacement = %{current | turn_count: current.turn_count + 1, updated_at_ms: now_ms()}

        case Store.compare_and_swap(server, @contexts, key, current, replacement) do
          :ok -> {:ok, replacement}
          {:error, :mismatch} -> increment_turn(direction, peer_id, context_id, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Stores an inbound task. The task table is the inbound A2A surface; outbound
  tasks live in the owner-scoped table (`put_owned_task/3`).
  """
  @spec put_task(map(), keyword()) :: :ok | {:error, term()}
  def put_task(task, opts \\ []) when is_map(task) do
    case normalize_task(task) do
      %{direction: :inbound, id: id} = record when is_binary(id) ->
        Store.put(store(opts), @tasks, id, record)

      _ ->
        {:error, :invalid_task}
    end
  end

  @doc """
  Returns an inbound task. Legacy outbound records still in the task table are
  never returned, so no inbound lookup, list, subscription or cancel sees them.
  """
  @spec get_task(binary(), keyword()) :: map() | nil
  def get_task(task_id, opts \\ []) do
    case fetch_task(task_id, opts) do
      {:ok, task} -> task
      {:error, _reason} -> nil
    end
  end

  @doc """
  Like `get_task/2`, but an unreadable store is `{:error, :store_unavailable}`
  rather than an unknown task. Peer-facing reads use this.
  """
  @spec fetch_task(binary(), keyword()) :: {:ok, map() | nil} | {:error, :store_unavailable}
  def fetch_task(task_id, opts \\ []), do: inbound_task(store(opts), task_id)

  @spec update_task(binary(), (map() -> map()), keyword()) :: {:ok, map()} | {:error, term()}
  def update_task(task_id, fun, opts \\ []) when is_function(fun, 1) do
    server = store(opts)

    case inbound_task(server, task_id) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, current} ->
        replacement =
          current
          |> fun.()
          |> Map.merge(%{direction: :inbound, updated_at_ms: now_ms()})

        case Store.compare_and_swap(server, @tasks, task_id, current, replacement) do
          :ok -> {:ok, replacement}
          {:error, :mismatch} -> update_task(task_id, fun, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "A peer's newest inbound tasks, or `{:error, :store_unavailable}` when unreadable."
  @spec list_tasks(binary(), keyword()) :: {:ok, [map()]} | {:error, :store_unavailable}
  def list_tasks(peer_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_list) |> max(1)

    with {:ok, entries} <- Store.fetch_all(store(opts), @tasks) do
      {:ok,
       entries
       |> Enum.map(&elem(&1, 1))
       |> Enum.filter(&(&1.direction == :inbound and &1.peer_id == peer_id))
       |> Enum.sort_by(&{&1.updated_at_ms, &1.id}, :desc)
       |> Enum.take(limit)}
    end
  end

  defp inbound_task(server, task_id) do
    case Store.fetch(server, @tasks, task_id) do
      {:ok, %{direction: :inbound} = task} -> {:ok, task}
      {:ok, _absent_or_outbound} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records an outbound remote task for `owner`, keyed by peer and remote task id.

  A remote task id already recorded for another owner is never reassigned.
  """
  @spec put_owned_task(owner(), map(), keyword()) ::
          :ok | {:error, :foreign_task | :invalid_task | term()}
  def put_owned_task({agent_id, session_key}, task, opts \\ [])
      when owner?(agent_id, session_key) and is_map(task) do
    record =
      task
      |> normalize_task()
      |> Map.merge(%{direction: :outbound, agent_id: agent_id, session_key: session_key})

    if is_binary(record.peer_id) and is_binary(record.id) do
      put_owned_task_record({record.peer_id, record.id}, record, store(opts))
    else
      {:error, :invalid_task}
    end
  end

  @doc "Returns an outbound task only when it was recorded for `owner`."
  @spec owned_task(binary(), owner(), binary(), keyword()) :: map() | nil
  def owned_task(peer_id, {agent_id, session_key}, task_id, opts \\ [])
      when is_binary(peer_id) and owner?(agent_id, session_key) and is_binary(task_id) do
    case Store.get(store(opts), @outbound_tasks, {peer_id, task_id}) do
      %{agent_id: ^agent_id, session_key: ^session_key} = task -> task
      _ -> nil
    end
  end

  defp put_owned_task_record(
         key,
         %{agent_id: agent_id, session_key: session_key} = record,
         server
       ) do
    case Store.put_new(server, @outbound_tasks, key, record) do
      :ok ->
        :ok

      {:error, :exists} ->
        case Store.get(server, @outbound_tasks, key) do
          %{agent_id: ^agent_id, session_key: ^session_key} = current ->
            replacement = %{record | created_at_ms: current.created_at_ms}

            case Store.compare_and_swap(server, @outbound_tasks, key, current, replacement) do
              :ok -> :ok
              {:error, :mismatch} -> put_owned_task_record(key, record, server)
              {:error, reason} -> {:error, reason}
            end

          %{} ->
            {:error, :foreign_task}

          nil ->
            put_owned_task_record(key, record, server)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec append_message(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def append_message(attrs, opts \\ []) when is_map(attrs) do
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || Id.uuid7()

    message = %{
      id: id,
      direction: Map.get(attrs, :direction) || Map.get(attrs, "direction"),
      peer_id: Map.get(attrs, :peer_id) || Map.get(attrs, "peer_id"),
      context_id: Map.get(attrs, :context_id) || Map.get(attrs, "context_id"),
      task_id: Map.get(attrs, :task_id) || Map.get(attrs, "task_id"),
      role: Map.get(attrs, :role) || Map.get(attrs, "role"),
      text: Map.get(attrs, :text) || Map.get(attrs, "text") || "",
      created_at_ms: Map.get(attrs, :created_at_ms) || now_ms()
    }

    case Store.put_new(store(opts), @messages, id, message) do
      :ok ->
        {:ok, message}

      {:error, :exists} ->
        case get_message(id, opts) do
          %{} = existing -> {:ok, existing}
          _ -> {:error, :message_unavailable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_message(binary(), keyword()) :: map() | nil
  def get_message(message_id, opts \\ []) when is_binary(message_id) do
    Store.get(store(opts), @messages, message_id)
  end

  @doc """
  Returns a context's messages in order. `direction: :inbound | :outbound`
  restricts the transcript to one direction of the exchange.
  """
  @spec history(binary(), binary(), keyword()) :: [map()]
  def history(peer_id, context_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_list) |> max(1)
    direction = Keyword.get(opts, :direction)

    store(opts)
    |> Store.list(@messages)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.peer_id == peer_id and &1.context_id == context_id))
    |> Enum.filter(&(is_nil(direction) or &1.direction == direction))
    |> Enum.sort_by(&{&1.created_at_ms, &1.id}, :asc)
    |> Enum.take(-limit)
  end

  defp normalize_task(task) do
    now = now_ms()

    %{
      id: Map.get(task, :id) || Map.get(task, "id"),
      direction: Map.get(task, :direction) || Map.get(task, "direction"),
      peer_id: Map.get(task, :peer_id) || Map.get(task, "peer_id"),
      context_id: Map.get(task, :context_id) || Map.get(task, "context_id"),
      run_id: Map.get(task, :run_id) || Map.get(task, "run_id"),
      state: Map.get(task, :state) || Map.get(task, "state") || "TASK_STATE_SUBMITTED",
      answer: Map.get(task, :answer) || Map.get(task, "answer"),
      error: Map.get(task, :error) || Map.get(task, "error"),
      runner_lease_id: Map.get(task, :runner_lease_id) || Map.get(task, "runner_lease_id"),
      runner_lease_expires_at_ms:
        Map.get(task, :runner_lease_expires_at_ms) ||
          Map.get(task, "runner_lease_expires_at_ms"),
      created_at_ms: Map.get(task, :created_at_ms) || Map.get(task, "created_at_ms") || now,
      updated_at_ms: Map.get(task, :updated_at_ms) || Map.get(task, "updated_at_ms") || now
    }
  end

  defp context_key(direction, peer_id, context_id), do: {direction, peer_id, context_id}
  defp default_key(peer_id, {agent_id, session_key}), do: {agent_id, session_key, peer_id}
  defp store(opts), do: Keyword.get(opts, :store, Store)
  defp now_ms, do: System.system_time(:millisecond)
end

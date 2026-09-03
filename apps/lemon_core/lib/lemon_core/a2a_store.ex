defmodule LemonCore.A2AStore do
  @moduledoc """
  Typed persistent storage for A2A peer contexts, tasks, and messages.

  Remote context identifiers are never used as Lemon session keys. Callers
  store an independently-derived private session key in the context record.
  """

  alias LemonCore.{Id, Store}

  @contexts :a2a_contexts
  @tasks :a2a_tasks
  @messages :a2a_messages
  @defaults :a2a_default_contexts
  @max_list 1_000

  @type direction :: :inbound | :outbound

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

  @spec default_context(binary(), keyword()) :: map() | nil
  def default_context(peer_id, opts \\ []) do
    case Store.get(store(opts), @defaults, peer_id) do
      nil -> nil
      context_id -> get_context(:outbound, peer_id, context_id, opts)
    end
  end

  @spec set_default_context(binary(), binary(), keyword()) :: :ok | {:error, term()}
  def set_default_context(peer_id, context_id, opts \\ []) do
    Store.put(store(opts), @defaults, peer_id, context_id)
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

  @spec put_task(map(), keyword()) :: :ok | {:error, term()}
  def put_task(task, opts \\ []) when is_map(task) do
    id = Map.get(task, :id) || Map.get(task, "id")
    Store.put(store(opts), @tasks, id, normalize_task(task))
  end

  @spec get_task(binary(), keyword()) :: map() | nil
  def get_task(task_id, opts \\ []), do: Store.get(store(opts), @tasks, task_id)

  @spec update_task(binary(), (map() -> map()), keyword()) :: {:ok, map()} | {:error, term()}
  def update_task(task_id, fun, opts \\ []) when is_function(fun, 1) do
    server = store(opts)

    case Store.get(server, @tasks, task_id) do
      nil ->
        {:error, :not_found}

      current ->
        replacement = current |> fun.() |> Map.put(:updated_at_ms, now_ms())

        case Store.compare_and_swap(server, @tasks, task_id, current, replacement) do
          :ok -> {:ok, replacement}
          {:error, :mismatch} -> update_task(task_id, fun, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec list_tasks(binary(), keyword()) :: [map()]
  def list_tasks(peer_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_list) |> max(1)

    store(opts)
    |> Store.list(@tasks)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.peer_id == peer_id))
    |> Enum.sort_by(&{&1.updated_at_ms, &1.id}, :desc)
    |> Enum.take(limit)
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

  @spec history(binary(), binary(), keyword()) :: [map()]
  def history(peer_id, context_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 100) |> min(@max_list) |> max(1)

    store(opts)
    |> Store.list(@messages)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.peer_id == peer_id and &1.context_id == context_id))
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
  defp store(opts), do: Keyword.get(opts, :store, Store)
  defp now_ms, do: System.system_time(:millisecond)
end

defmodule LemonCore.LifecycleFenceStore do
  @moduledoc """
  Durable fences for destructive session lifecycle operations
  (`sessions.reset`, `sessions.delete`).

  One row per session key. A `"held"` row refuses every new execution for the
  session. It records a random `generation`, the owning process and node, and
  the operation. The router acquires and releases rows inside its serialized
  admission boundary (`LemonRouter.with_session_lifecycle_fence/2`). Lifecycle
  mutations are bound to the generation they were granted and stop when it is
  no longer held.

  Rows survive router restarts. A held row whose owner has died is released
  only by the router's reconcile check. If the owner had marked the row
  `finished` (its mutation returned), the row is removed; otherwise it is
  replaced by an `"outcome_unknown"` row, which records that the operation may
  have partly applied and no longer refuses execution. Rows never expire by time.

  Reads are strict: an unreadable row never reads as "not fenced".
  """

  alias LemonCore.Store

  @table :session_lifecycle_fences

  @type fence :: %{
          required(:state) => String.t(),
          required(:generation) => String.t(),
          optional(:owner_pid) => pid(),
          optional(:owner_node) => node(),
          optional(:operation) => atom(),
          optional(:acquisition_id) => String.t(),
          optional(:finished) => boolean(),
          optional(:acquired_at_ms) => integer(),
          optional(:reconciled_at_ms) => integer()
        }

  @doc false
  def table, do: @table

  @doc "The session's fence row, `{:ok, nil}` when none was ever written."
  @spec fetch(String.t()) :: {:ok, fence() | nil} | {:error, :unavailable}
  def fetch(session_key) when is_binary(session_key) do
    case Store.fetch(@table, session_key) do
      {:ok, value} when is_map(value) or is_nil(value) -> {:ok, value}
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "`:ok` unless a held fence (or an unreadable row) refuses execution for the session."
  @spec check_admission(String.t()) ::
          :ok | {:error, :session_lifecycle_in_progress | :session_lifecycle_unavailable}
  def check_admission(session_key) do
    case fetch(session_key) do
      {:ok, %{state: "held"}} -> {:error, :session_lifecycle_in_progress}
      {:ok, _released_or_absent} -> :ok
      {:error, _} -> {:error, :session_lifecycle_unavailable}
    end
  end

  @doc "`:ok` while `generation` still holds the session's fence."
  @spec check_generation(String.t(), String.t()) :: :ok | {:error, :fence_lost | :unavailable}
  def check_generation(session_key, generation) do
    case fetch(session_key) do
      {:ok, %{state: "held", generation: ^generation}} -> :ok
      {:ok, _} -> {:error, :fence_lost}
      {:error, _} -> {:error, :unavailable}
    end
  end

  @doc "Every held fence."
  @spec held() :: {:ok, [{String.t(), fence()}]} | {:error, :unavailable}
  def held do
    case Store.fetch_all(@table) do
      {:ok, rows} -> {:ok, Enum.filter(rows, &match?({_key, %{state: "held"}}, &1))}
      _ -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  # Router-owned: called only from the serialized admission boundary.
  @spec acquire(String.t(), pid(), atom(), String.t()) ::
          {:ok, fence()} | {:error, :held | :unavailable | :outcome_unknown}
  def acquire(session_key, owner, operation, acquisition_id)
      when is_pid(owner) and is_binary(acquisition_id) do
    with {:ok, current} <- fetch(session_key) do
      case current do
        %{state: "held"} ->
          {:error, :held}

        _released_or_absent ->
          fence = %{
            state: "held",
            generation: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
            owner_pid: owner,
            owner_node: node(owner),
            operation: operation,
            acquisition_id: acquisition_id,
            acquired_at_ms: System.system_time(:millisecond)
          }

          write =
            if is_nil(current),
              do: Store.put_new(Store, @table, session_key, fence, durable: true),
              else:
                Store.compare_and_swap(Store, @table, session_key, current, fence, durable: true)

          case write do
            :ok -> {:ok, fence}
            {:error, :outcome_unknown} -> {:error, :outcome_unknown}
            _ -> {:error, :unavailable}
          end
      end
    end
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  @doc false
  # Router-owned: remove the fence `generation` holds; another generation's row is untouched.
  @spec release(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def release(session_key, generation) do
    case fetch(session_key) do
      {:ok, %{state: "held", generation: ^generation} = fence} ->
        case Store.compare_and_delete(Store, @table, session_key, fence, durable: true) do
          :ok -> :ok
          _ -> {:error, :unavailable}
        end

      {:ok, _} ->
        :ok

      {:error, _} ->
        {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  # Owner-only: record that the operation holding `generation` returned, so a
  # later reconcile releases the row instead of marking the outcome unknown.
  @spec mark_finished(String.t(), String.t()) :: :ok | {:error, :fence_lost | :unavailable}
  def mark_finished(session_key, generation) do
    case fetch(session_key) do
      {:ok, %{state: "held", generation: ^generation} = fence} ->
        finished = Map.put(fence, :finished, true)

        case Store.compare_and_swap(Store, @table, session_key, fence, finished, durable: true) do
          :ok -> :ok
          _ -> {:error, :unavailable}
        end

      {:ok, _} ->
        {:error, :fence_lost}

      {:error, _} ->
        {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc false
  # Router-owned: after its reconcile check, stop refusing execution for a
  # dead owner's fence. A finished operation's row is removed; otherwise the
  # row records that the operation may have partly applied.
  @spec release_reconciled(String.t(), String.t()) ::
          {:ok, :finished | :outcome_unknown} | {:error, :unavailable}
  def release_reconciled(session_key, generation) do
    case fetch(session_key) do
      {:ok, %{state: "held", generation: ^generation, finished: true}} ->
        with :ok <- release(session_key, generation), do: {:ok, :finished}

      {:ok, %{state: "held", generation: ^generation} = fence} ->
        unknown =
          fence
          |> Map.take([:generation, :operation, :owner_node, :acquired_at_ms])
          |> Map.merge(%{
            state: "outcome_unknown",
            reconciled_at_ms: System.system_time(:millisecond)
          })

        case Store.compare_and_swap(Store, @table, session_key, fence, unknown, durable: true) do
          :ok -> {:ok, :outcome_unknown}
          _ -> {:error, :unavailable}
        end

      {:ok, _} ->
        {:ok, :finished}

      {:error, _} ->
        {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end
end

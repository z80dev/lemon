defmodule LemonRouter.RunReceiptStore do
  @moduledoc """
  Content-free admission receipts, owned by the router and keyed by fixed run ID.

  `fetch/1` distinguishes absence from storage failure. `put/1` writes the initial
  disposition once; `update/2` uses compare-and-swap and never creates a missing
  receipt. Only mode and target can change after admission. An optional private
  `:request_identity` digest binds orchestrator replay to its admission identity;
  it is not a wire projection field. Before retargeting a merge, the coordinator
  fences existing receipts as `:outcome_unknown` until the applied disposition
  is durable. Prompts, execution metadata and error terms are never retained here.

  The optional first argument selects a `LemonCore.Store` instance. Every receipt
  write and existing-record read requires a successful `Store.sync/1` barrier
  before acknowledgement. A visible row alone cannot prove a previously failed
  write barrier reached stable storage. Barrier failures return
  `{:error, {:sync_failed, reason}}`; storage backends without sync fail closed.
  """

  alias LemonCore.{MapHelpers, Store}

  @table :run_receipts
  @keys [:run_id, :session_key, :agent_id, :profile_id, :dependent_profile_ids, :state, :effective_mode, :target_run_id, :request_identity, :terminal]
  @modes [
    :new_run,
    :queued,
    :merged,
    :steer_pending,
    :steer,
    :steer_backlog_pending,
    :steer_backlog,
    :redirect_pending,
    :redirect,
    :interrupt
  ]

  @type receipt :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          required(:state) => :accepted | :outcome_unknown,
          required(:effective_mode) => atom() | nil,
          required(:target_run_id) => binary() | nil,
          optional(:request_identity) => binary(),
          optional(:profile_id) => binary() | nil,
          optional(:agent_id) => binary() | nil,
          optional(:dependent_profile_ids) => [binary()],
          optional(:terminal) => true
        }

  @doc false
  def fetch_all do
    with {:ok, rows} <- Store.fetch_all(@table),
         :ok <- sync(Store) do
      Enum.reduce_while(rows, {:ok, []}, fn {id, row}, {:ok, acc} ->
        case normalize(row, id) do
          {:ok, receipt} -> {:cont, {:ok, [{id, receipt} | acc]}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def retain_terminal_evidence(server \\ Store, run_id) do
    case Store.fetch(server, :runs, run_id) do
      {:ok, record} when is_map(record) ->
        if is_map(MapHelpers.get_key(record, :summary)) do
          with :ok <- mark_terminal(server, LemonRouter.RunOrchestrator.admission_table(), run_id),
               :ok <- mark_terminal(server, @table, run_id) do
            sync(server)
          end
        else
          :ok
        end

      {:ok, _nonterminal_or_absent} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp mark_terminal(server, table, run_id) do
    case Store.fetch(server, table, run_id) do
      {:ok, nil} -> :ok
      {:ok, %{terminal: true}} -> :ok
      {:ok, current} when is_map(current) ->
        case Store.compare_and_swap(server, table, run_id, current, Map.put(current, :terminal, true)) do
          :ok -> :ok
          {:error, :mismatch} -> mark_terminal(server, table, run_id)
          error -> error
        end
      _ -> {:error, :invalid_terminal_evidence}
    end
  end

  @spec fetch(Store.server(), binary()) :: {:ok, receipt() | nil} | {:error, term()}
  def fetch(server \\ Store, run_id) do
    case Store.fetch(server, @table, run_id) do
      {:ok, nil} -> {:ok, nil}
      {:ok, receipt} ->
        with {:ok, receipt} <- normalize(receipt, run_id),
             :ok <- sync(server) do
          {:ok, receipt}
        end
      {:error, _reason} = error -> error
    end
  end

  @spec put(Store.server(), receipt()) :: :ok | {:error, term()}
  def put(server \\ Store, receipt)

  def put(server, receipt) when is_map(receipt) do
    with {:ok, receipt} <- normalize(Map.delete(receipt, :dependent_profile_ids), Map.get(receipt, :run_id)),
         {:ok, admission} <- Store.fetch(server, LemonRouter.RunOrchestrator.admission_table(), receipt.run_id) do
      receipt =
        case LemonRouter.NativeLineage.dependent_profile_ids(admission) do
          [] -> receipt
          dependencies -> Map.put(receipt, :dependent_profile_ids, dependencies)
        end
      case Store.put_new(server, @table, receipt.run_id, receipt) do
        :ok ->
          with :ok <- sync(server), do: retain_terminal_evidence(server, receipt.run_id)
        {:error, :exists} -> existing_receipt(server, receipt)
        {:error, _reason} = error -> error
      end
    end
  end

  def put(_server, _receipt), do: {:error, :invalid_receipt}

  @doc "Updates only an existing receipt's effective mode and invocation target."
  @spec update(Store.server(), binary(), map()) :: :ok | {:error, term()}
  def update(server \\ Store, run_id, changes) when is_map(changes) do
    case fetch(server, run_id) do
      {:ok, nil} ->
        :ok

      {:ok, current} ->
        replacement =
          current
          |> Map.merge(Map.take(changes, [:effective_mode, :target_run_id]))
          |> Map.put(:state, :accepted)

        with {:ok, replacement} <- normalize(replacement, run_id) do
          if replacement == current do
            :ok
          else
            case Store.compare_and_swap(server, @table, run_id, current, replacement) do
              :ok -> sync(server)
              {:error, :mismatch} -> update(server, run_id, changes)
              {:error, _reason} = error -> error
            end
          end
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Durably fences an existing receipt before its merge target can change."
  @spec mark_unknown(Store.server(), binary()) :: :ok | {:error, term()}
  def mark_unknown(server \\ Store, run_id) do
    case fetch(server, run_id) do
      {:ok, nil} ->
        :ok

      {:ok, %{state: :outcome_unknown}} ->
        :ok

      {:ok, current} ->
        replacement = %{current | state: :outcome_unknown, effective_mode: nil, target_run_id: nil}

        case Store.compare_and_swap(server, @table, run_id, current, replacement) do
          :ok -> sync(server)
          {:error, :mismatch} -> mark_unknown(server, run_id)
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_receipt(server, receipt) do
    case fetch(server, receipt.run_id) do
      {:ok, ^receipt} -> :ok
      {:ok, _other} -> {:error, :receipt_conflict}
      {:error, _reason} = error -> error
    end
  end

  defp sync(server) do
    case Store.sync(server) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sync_failed, reason}}
    end
  end

  defp normalize(
         %{run_id: run_id, session_key: session_key, state: :accepted,
           effective_mode: mode, target_run_id: target} = receipt,
         run_id
       )
       when is_binary(run_id) and run_id != "" and is_binary(session_key) and
              session_key != "" and mode in @modes and is_binary(target) and target != "" do
    normalize_identity(receipt)
  end

  defp normalize(
         %{run_id: run_id, session_key: session_key, state: :outcome_unknown,
           effective_mode: nil, target_run_id: nil} = receipt,
         run_id
       )
       when is_binary(run_id) and run_id != "" and is_binary(session_key) and session_key != "" do
    normalize_identity(receipt)
  end

  defp normalize(_receipt, _run_id), do: {:error, :invalid_receipt}

  defp normalize_identity(receipt) do
    dependencies = Map.get(receipt, :dependent_profile_ids, [])
    if is_list(dependencies) and Enum.all?(dependencies, &(is_binary(&1) and &1 != "")) do
      case Map.get(receipt, :request_identity) do
        nil -> {:ok, receipt |> Map.take(@keys) |> Map.delete(:request_identity)}
        identity when is_binary(identity) and identity != "" -> {:ok, Map.take(receipt, @keys)}
        _invalid -> {:error, :invalid_receipt}
      end
    else
      {:error, :invalid_receipt}
    end
  end
end

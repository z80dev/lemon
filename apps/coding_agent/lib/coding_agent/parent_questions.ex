defmodule CodingAgent.ParentQuestions do
  @moduledoc """
  Store and lifecycle helpers for subagent clarification requests sent to a
  parent session.

  The child `ask_parent` tool creates requests here and waits for a terminal
  state. The parent-facing `parent_question` tool lists and answers waiting
  requests scoped to the current session.
  """

  alias CodingAgent.ParentQuestionStoreServer
  alias LemonCore.{Bus, Event, Introspection}

  @table :coding_agent_parent_questions
  @dets_table :coding_agent_parent_questions_dets
  @max_events 100
  @default_ttl_seconds 86_400

  @type request_id :: String.t()
  @type request_record :: map()

  @spec request(map()) :: {:ok, request_record()} | {:error, term()}
  def request(attrs) when is_map(attrs) do
    ensure_table()

    child_scope_id = Map.get(attrs, :child_scope_id) || Map.get(attrs, "child_scope_id")

    cond do
      not is_binary(child_scope_id) or String.trim(child_scope_id) == "" ->
        {:error, :missing_child_scope}

      match?({:ok, _}, open_request_for_child_scope(child_scope_id)) ->
        {:error, :already_waiting}

      true ->
        request_id = new_request(attrs)
        {:ok, record, _events} = get(request_id)
        emit_lifecycle(:parent_question_requested, record)
        {:ok, record}
    end
  end

  @spec answer(request_id(), String.t(), keyword()) :: :ok | {:error, term()}
  def answer(request_id, answer_text, opts \\ [])
      when is_binary(request_id) and is_binary(answer_text) do
    with {:ok, record, _events} <- get(request_id),
         :ok <- ensure_waiting(record),
         :ok <- ensure_session_scope(record, opts) do
      meta = %{
        answered_by_session_key: Keyword.get(opts, :session_key),
        answered_by_agent_id: Keyword.get(opts, :agent_id)
      }

      mark_answered(request_id, answer_text, meta)
      {:ok, updated, _events} = get(request_id)
      emit_lifecycle(:parent_question_answered, updated, %{answer: answer_text})
      :ok
    end
  end

  @spec timeout(request_id()) :: :ok | {:error, term()}
  def timeout(request_id) when is_binary(request_id) do
    with {:ok, record, _events} <- get(request_id),
         :ok <- ensure_waiting(record) do
      mark_timed_out(request_id)
      {:ok, updated, _events} = get(request_id)
      emit_lifecycle(:parent_question_timed_out, updated)
      :ok
    end
  end

  @spec fail(request_id(), term()) :: :ok | {:error, term()}
  def fail(request_id, reason) when is_binary(request_id) do
    with {:ok, record, _events} <- get(request_id),
         :ok <- ensure_waiting(record) do
      mark_error(request_id, reason)
      {:ok, updated, _events} = get(request_id)
      emit_lifecycle(:parent_question_error, updated, %{error: normalize_reason(reason)})
      :ok
    end
  end

  @spec cancel(request_id(), term()) :: :ok | {:error, term()}
  def cancel(request_id, reason) when is_binary(request_id) do
    with {:ok, record, _events} <- get(request_id),
         :ok <- ensure_waiting(record) do
      mark_cancelled(request_id, reason)
      {:ok, updated, _events} = get(request_id)
      emit_lifecycle(:parent_question_cancelled, updated, %{reason: normalize_reason(reason)})
      :ok
    end
  end

  @spec open_request_for_child_scope(String.t()) :: {:ok, request_record()} | {:error, :not_found}
  def open_request_for_child_scope(child_scope_id) when is_binary(child_scope_id) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.find_value({:error, :not_found}, fn
      {_id, %{child_scope_id: ^child_scope_id, status: :waiting} = record, _events} ->
        {:ok, record}

      _ ->
        false
    end)
  end

  @spec list(keyword()) :: [{request_id(), request_record()}]
  def list(opts \\ []) do
    ensure_table()

    status = Keyword.get(opts, :status, :all)
    parent_session_key = Keyword.get(opts, :parent_session_key)
    parent_agent_id = Keyword.get(opts, :parent_agent_id)

    :ets.foldl(
      fn {request_id, record, _events}, acc ->
        if matches_filters?(record, status, parent_session_key, parent_agent_id) do
          [{request_id, record} | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.sort_by(fn {_request_id, record} -> Map.get(record, :inserted_at, 0) end)
  end

  @spec get(request_id()) :: {:ok, request_record(), [term()]} | {:error, :not_found}
  def get(request_id) when is_binary(request_id) do
    ensure_table()

    case :ets.lookup(@table, request_id) do
      [{^request_id, record, events}] -> {:ok, record, Enum.reverse(events)}
      _ -> {:error, :not_found}
    end
  end

  @spec append_event(request_id(), term()) :: :ok
  def append_event(request_id, event) when is_binary(request_id) do
    ensure_table()

    case :ets.lookup(@table, request_id) do
      [{^request_id, record, events}] ->
        events = [event | events] |> Enum.take(@max_events)
        record = Map.put(record, :updated_at, System.system_time(:second))
        insert_record(request_id, record, events)
        :ok

      _ ->
        :ok
    end
  end

  @spec clear() :: :ok
  def clear do
    ParentQuestionStoreServer.clear(CodingAgent.ParentQuestionStoreServer)
  end

  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} =
      ParentQuestionStoreServer.cleanup(CodingAgent.ParentQuestionStoreServer, ttl_seconds)

    :ok
  end

  @spec request_topic(request_id()) :: String.t()
  def request_topic(request_id) when is_binary(request_id), do: "parent_question:#{request_id}"

  @spec insert_record(request_id(), request_record(), [term()]) :: :ok
  def insert_record(request_id, record, events) do
    :ets.insert(@table, {request_id, record, events})

    if dets_open?() do
      :dets.insert(@dets_table, {request_id, record, events})
    end

    :ok
  end

  @spec dets_open?() :: boolean()
  def dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp new_request(attrs) do
    request_id = generate_id()
    now = System.system_time(:second)

    record =
      Map.merge(
        %{
          id: request_id,
          status: :waiting,
          inserted_at: now,
          updated_at: now,
          description: nil,
          parent_run_id: nil,
          child_run_id: nil,
          child_scope_id: nil,
          task_id: nil,
          parent_session_key: nil,
          parent_agent_id: nil,
          question: nil,
          why_blocked: nil,
          options: [],
          recommended_option: nil,
          can_continue_without_answer: false,
          fallback: nil,
          timeout_ms: nil,
          answer: nil,
          answer_meta: %{},
          answered_at: nil,
          completed_at: nil,
          error: nil,
          meta: %{}
        },
        normalize_attrs(attrs)
      )

    insert_record(request_id, record, [])
    request_id
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.into(%{}, fn {key, value} ->
      {normalize_attr_key(key), value}
    end)
    |> Map.update(:options, [], fn options -> if is_list(options), do: options, else: [] end)
    |> Map.update(:meta, %{}, fn meta -> if is_map(meta), do: meta, else: %{} end)
  end

  defp normalize_attr_key(key) when is_atom(key), do: key

  defp normalize_attr_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end

  defp mark_answered(request_id, answer_text, meta) do
    update_record(request_id, fn record ->
      now = System.system_time(:second)

      record
      |> Map.put(:status, :answered)
      |> Map.put(:answer, answer_text)
      |> Map.put(:answer_meta, meta || %{})
      |> Map.put(:answered_at, now)
      |> Map.put(:completed_at, now)
    end)
  end

  defp mark_timed_out(request_id) do
    update_record(request_id, fn record ->
      record
      |> Map.put(:status, :timed_out)
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  defp mark_error(request_id, reason) do
    update_record(request_id, fn record ->
      record
      |> Map.put(:status, :error)
      |> Map.put(:error, normalize_reason(reason))
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  defp mark_cancelled(request_id, reason) do
    update_record(request_id, fn record ->
      record
      |> Map.put(:status, :cancelled)
      |> Map.put(:error, normalize_reason(reason))
      |> Map.put(:completed_at, System.system_time(:second))
    end)
  end

  defp update_record(request_id, fun) do
    ensure_table()

    case :ets.lookup(@table, request_id) do
      [{^request_id, record, events}] ->
        updated =
          record
          |> fun.()
          |> Map.put(:updated_at, System.system_time(:second))

        insert_record(request_id, updated, events)
        :ok

      _ ->
        :ok
    end
  end

  defp emit_lifecycle(event_type, record, extra_payload \\ %{}) do
    payload =
      %{
        request_id: record.id,
        status: record.status,
        parent_run_id: record.parent_run_id,
        child_run_id: record.child_run_id,
        child_scope_id: record.child_scope_id,
        task_id: record.task_id,
        session_key: record.parent_session_key,
        agent_id: record.parent_agent_id,
        description: record.description,
        question: record.question,
        why_blocked: record.why_blocked,
        options: record.options,
        recommended_option: record.recommended_option,
        can_continue_without_answer: record.can_continue_without_answer,
        fallback: record.fallback,
        timeout_ms: record.timeout_ms,
        meta: record.meta
      }
      |> Map.merge(extra_payload)

    event =
      Event.new(event_type, payload, %{
        run_id: record.child_run_id || record.parent_run_id,
        parent_run_id: record.parent_run_id,
        session_key: record.parent_session_key,
        agent_id: record.parent_agent_id,
        request_id: record.id
      })

    append_event(record.id, %{type: event_type, ts_ms: event.ts_ms, payload: payload})
    Bus.broadcast(request_topic(record.id), event)

    if is_binary(record.child_run_id) do
      Bus.broadcast(Bus.run_topic(record.child_run_id), event)
    end

    if is_binary(record.parent_run_id) and record.parent_run_id != record.child_run_id do
      Bus.broadcast(Bus.run_topic(record.parent_run_id), event)
    end

    Introspection.record(
      event_type,
      payload,
      run_id: record.child_run_id || record.parent_run_id,
      parent_run_id: record.parent_run_id,
      session_key: record.parent_session_key,
      agent_id: record.parent_agent_id,
      provenance: :direct
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp matches_filters?(record, status, parent_session_key, parent_agent_id) do
    status_matches?(record, status) and
      session_key_matches?(record, parent_session_key) and
      agent_id_matches?(record, parent_agent_id)
  end

  defp status_matches?(_record, :all), do: true
  defp status_matches?(record, status), do: Map.get(record, :status) == status

  defp session_key_matches?(_record, nil), do: true

  defp session_key_matches?(record, session_key),
    do: Map.get(record, :parent_session_key) == session_key

  defp agent_id_matches?(_record, nil), do: true
  defp agent_id_matches?(record, agent_id), do: Map.get(record, :parent_agent_id) == agent_id

  defp ensure_waiting(%{status: :waiting}), do: :ok
  defp ensure_waiting(%{status: status}), do: {:error, {:invalid_status, status}}

  defp ensure_session_scope(record, opts) do
    current_session_key = Keyword.get(opts, :session_key)

    if is_binary(current_session_key) and is_binary(record.parent_session_key) and
         current_session_key != record.parent_session_key do
      {:error, :wrong_session}
    else
      :ok
    end
  end

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason, limit: 80)

  defp ensure_table do
    ParentQuestionStoreServer.ensure_table(CodingAgent.ParentQuestionStoreServer)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

defmodule LemonChannels.Supervision do
  @moduledoc """
  Durable, channel-owned remote supervision for automation runs.

  Bind a normalized target before submitting a run with `bind_run/3`. Bindings
  are immutable and scoped to the exact session. Only an absent binding permits
  deriving a target from a canonical channel-peer session key; no owner or known
  target fallback is used.

  `notify/2` persists a bounded terminal notice before Outbox admission. `:ok`
  means queued (or already delivered), not platform delivery. Definite admission
  rejection is retried at most three times, including across restarts. Unknown
  admission, missing receipts and interrupted in-flight delivery are never
  replayed. Outbox alone owns platform retries. `status/1` exposes metadata only.
  Callers must supply an intentionally public summary, never a raw run response.
  Default binding, target lookup and status calls depend only on Store. Notice
  intent is durable even when the worker is temporarily absent: that call returns
  `{:error, :supervision_unavailable}`, and restart recovers the pending intent.
  A production deployment must use a persistent Core Store backend for recovery
  across VM restarts; the ETS backend is intentionally ephemeral.

  The optional leading server argument and `start_link/1` options `:name`,
  `:store`, `:enqueue`, `:retry_ms` and `:receipt_timeout_ms` support isolated
  runtime instances without changing application configuration. Production uses
  the supervised singleton, Core Store and `LemonChannels.Outbox.enqueue/1`.
  Starting the default singleton registers this module with
  `LemonCore.ChannelSupervision`; registration survives worker downtime so its
  Store-backed operations remain available. Named or unnamed isolated workers
  never replace the runtime provider.
  """

  use GenServer

  @behaviour LemonCore.ChannelSupervision

  alias LemonChannels.{OutboundPayload, SupervisionNotice, SupervisionStore}
  alias LemonCore.SessionKey

  @max_attempts 3
  @call_timeout 30_000

  @type target :: %{channel_id: binary(), account_id: binary(), peer: OutboundPayload.peer()}

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: [])) do
      {:ok, _pid} = result ->
        if name == __MODULE__, do: :ok = LemonCore.ChannelSupervision.register(__MODULE__)
        result

      error ->
        error
    end
  end

  @impl true
  @spec bind_run(binary(), binary(), target()) :: :ok | {:error, atom()}
  def bind_run(run_id, session_key, target) do
    with :ok <- valid_scope(run_id, session_key),
         {:ok, target} <- SupervisionNotice.target(target) do
      SupervisionStore.bind(LemonCore.Store, run_id, %{session_key: session_key, target: target})
    end
  end

  @spec bind_run(GenServer.server(), binary(), binary(), target()) :: :ok | {:error, atom()}
  def bind_run(server, run_id, session_key, target) do
    with :ok <- valid_scope(run_id, session_key),
         {:ok, target} <- SupervisionNotice.target(target) do
      call(server, {:bind, run_id, session_key, target})
    end
  end

  @impl true
  @spec target_for_run(binary(), binary()) :: {:ok, target()} | :none | {:error, atom()}
  def target_for_run(run_id, session_key) do
    with :ok <- valid_scope(run_id, session_key) do
      lookup_target(LemonCore.Store, run_id, session_key)
    end
  end

  @spec target_for_run(GenServer.server(), binary(), binary()) ::
          {:ok, target()} | :none | {:error, atom()}
  def target_for_run(server, run_id, session_key) do
    with :ok <- valid_scope(run_id, session_key) do
      call(server, {:target, run_id, session_key})
    end
  end

  @impl true
  @spec notify(target(), map()) :: :ok | {:error, atom()}
  def notify(target, notice) do
    with {:ok, target} <- SupervisionNotice.target(target),
         {:ok, identity, text} <- SupervisionNotice.render(notice),
         {:ok, _record} <- admit_notice(LemonCore.Store, target, identity, text) do
      case call(__MODULE__, {:notify, target, identity, text}) do
        {:error, :supervision_unavailable} = error ->
          # If restart raced admission, its initial scan may have missed us.
          if pid = Process.whereis(__MODULE__), do: send(pid, {:submit, identity})
          error

        result ->
          result
      end
    end
  end

  @spec notify(GenServer.server(), target(), map()) :: :ok | {:error, atom()}
  def notify(server, target, notice) do
    with {:ok, target} <- SupervisionNotice.target(target),
         {:ok, identity, text} <- SupervisionNotice.render(notice) do
      call(server, {:notify, target, identity, text})
    end
  end

  @doc "Metadata only; accepts a notice map or `{kind, id, run_id, status}` identity."
  @spec status(map() | tuple()) :: {:ok, map()} | :none | {:error, atom()}
  def status(notice) do
    with {:ok, identity} <- SupervisionNotice.identity(notice) do
      notice_status(LemonCore.Store, identity)
    end
  end

  @spec status(GenServer.server(), map() | tuple()) :: {:ok, map()} | :none | {:error, atom()}
  def status(server, notice) do
    with {:ok, identity} <- SupervisionNotice.identity(notice) do
      call(server, {:status, identity})
    end
  end

  @impl true
  def init(opts) do
    state = %{
      store: Keyword.get(opts, :store, LemonCore.Store),
      enqueue: Keyword.get(opts, :enqueue, &LemonChannels.Outbox.enqueue/1),
      retry_ms: Keyword.get(opts, :retry_ms, 1_000),
      receipt_timeout_ms: Keyword.get(opts, :receipt_timeout_ms, 60_000),
      refs: %{},
      ready: false
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state), do: recover(state)

  @impl true
  def handle_call({:bind, run_id, session_key, target}, _from, state) do
    result =
      SupervisionStore.bind(state.store, run_id, %{session_key: session_key, target: target})

    {:reply, result, state}
  end

  def handle_call({:target, run_id, session_key}, _from, state) do
    {:reply, lookup_target(state.store, run_id, session_key), state}
  end

  def handle_call({:status, identity}, _from, state) do
    {:reply, notice_status(state.store, identity), state}
  end

  def handle_call({:notify, _target, _identity, _text}, _from, %{ready: false} = state),
    do: {:reply, {:error, :store_unavailable}, state}

  def handle_call({:notify, target, identity, text}, _from, state) do
    case admit_notice(state.store, target, identity, text) do
      {:ok, %{delivery_state: :pending, attempts: 0} = record} ->
        {result, state} = submit(record, state)
        {:reply, result, state}

      {:ok, record} ->
        {:reply, result(record), state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:recover, state), do: recover(state)

  def handle_info({:submit, identity}, state) do
    case SupervisionStore.notice(state.store, identity) do
      {:ok, %{delivery_state: :pending} = record} ->
        {_result, state} = submit(record, state)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:supervision_receipt, ref, receipt}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{identity, timer}, refs} ->
        Process.cancel_timer(timer)
        {delivery_state, reason} = receipt_status(receipt)
        settle(state.store, identity, delivery_state, reason)
        {:noreply, %{state | refs: refs}}
    end
  end

  def handle_info({:receipt_timeout, ref}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{identity, _timer}, refs} ->
        settle(state.store, identity, :unknown, :receipt_timeout)
        {:noreply, %{state | refs: refs}}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp recover(state) do
    case SupervisionStore.notices(state.store) do
      {:ok, records} ->
        Enum.each(records, fn
          %{delivery_state: :pending, identity: identity} ->
            send(self(), {:submit, identity})

          %{delivery_state: status} = record when status in [:submitting, :queued] ->
            transition(state.store, record, :unknown, :interrupted)

          _ ->
            :ok
        end)

        {:noreply, %{state | ready: true}}

      _ ->
        Process.send_after(self(), :recover, state.retry_ms)
        {:noreply, state}
    end
  end

  defp submit(%{attempts: attempts} = record, state) when attempts >= @max_attempts do
    {persist_result(transition(state.store, record, :rejected, :admission_exhausted)), state}
  end

  defp submit(record, state) do
    submitting = %{
      record
      | delivery_state: :submitting,
        attempts: record.attempts + 1,
        reason: nil,
        updated_at_ms: System.system_time(:millisecond)
    }

    # This durable boundary is intentionally conservative: a crash after it may
    # lose a notice, but must never repeat a possibly accepted platform write.
    case SupervisionStore.replace_notice(state.store, record.identity, record, submitting) do
      :ok ->
        ref = make_ref()
        payload = payload(submitting, ref)
        admission = enqueue(state.enqueue, payload)
        admitted(admission, submitting, ref, state)

      error ->
        {error, state}
    end
  end

  defp admitted({:ok, _outbox_ref}, record, ref, state) do
    timer = Process.send_after(self(), {:receipt_timeout, ref}, state.receipt_timeout_ms)
    state = %{state | refs: Map.put(state.refs, ref, {record.identity, timer})}
    {persist_result(transition(state.store, record, :queued, nil)), state}
  end

  defp admitted({:error, reason}, record, _ref, state)
       when reason in [:channels_outbox_unavailable, :queue_full] do
    status = if record.attempts < @max_attempts, do: :pending, else: :rejected
    persisted = transition(state.store, record, status, reason)

    if match?({:ok, %{delivery_state: :pending}}, persisted) do
      Process.send_after(self(), {:submit, record.identity}, state.retry_ms)
    end

    {persist_result(persisted), state}
  end

  defp admitted(_ambiguous, record, ref, state) do
    # A late receipt can still resolve an admission timeout in this process.
    timer = Process.send_after(self(), {:receipt_timeout, ref}, state.receipt_timeout_ms)
    state = %{state | refs: Map.put(state.refs, ref, {record.identity, timer})}
    {persist_result(transition(state.store, record, :unknown, :outcome_unknown)), state}
  end

  defp enqueue(enqueue, payload) do
    enqueue.(payload)
  rescue
    _ -> {:error, :outcome_unknown}
  catch
    _, _ -> {:error, :outcome_unknown}
  end

  defp payload(record, ref) do
    target = record.target
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(record.identity)) |> Base.encode16()

    OutboundPayload.text(target.channel_id, target.account_id, target.peer, record.text,
      idempotency_key: "supervision:#{digest}",
      notify_pid: self(),
      notify_ref: ref,
      meta: %{notify_tag: :supervision_receipt}
    )
  end

  defp settle(store, identity, status, reason) do
    case SupervisionStore.notice(store, identity) do
      {:ok, %{delivery_state: current} = record}
      when current in [:submitting, :queued, :unknown] ->
        transition(store, record, status, reason)

      _ ->
        :ok
    end
  end

  defp transition(store, record, status, reason) do
    next = %{
      record
      | delivery_state: status,
        reason: reason,
        updated_at_ms: System.system_time(:millisecond)
    }

    case SupervisionStore.replace_notice(store, record.identity, record, next) do
      :ok -> {:ok, next}
      error -> error
    end
  end

  defp persist_result({:ok, record}), do: result(record)
  defp persist_result(error), do: error

  defp result(%{delivery_state: status}) when status in [:queued, :delivered], do: :ok
  defp result(%{delivery_state: :pending, reason: nil}), do: {:error, :admission_pending}
  defp result(%{delivery_state: :pending, reason: reason}), do: {:error, reason}
  defp result(%{delivery_state: :rejected}), do: {:error, :admission_exhausted}
  defp result(%{delivery_state: :failed}), do: {:error, :delivery_failed}
  defp result(_), do: {:error, :outcome_unknown}

  defp receipt_status({:ok, _}), do: {:delivered, nil}
  defp receipt_status({:error, :unknown_channel}), do: {:failed, :delivery_failed}

  defp receipt_status({:error, {:http_error, code, _}}) when code in 400..499,
    do: {:failed, :delivery_failed}

  defp receipt_status(_), do: {:unknown, :outcome_unknown}

  defp metadata(%{identity: {kind, id, run_id, status}} = record) do
    record
    |> Map.take([:delivery_state, :attempts, :reason, :updated_at_ms])
    |> Map.merge(%{kind: kind, id: id, run_id: run_id, status: status})
  end

  defp lookup_target(store, run_id, session_key) do
    case SupervisionStore.binding(store, run_id) do
      {:ok, nil} -> origin_target(session_key)
      {:ok, %{session_key: ^session_key, target: target}} -> SupervisionNotice.target(target)
      {:ok, %{session_key: _}} -> {:error, :session_mismatch}
      {:ok, _} -> {:error, :invalid_binding}
      _ -> {:error, :store_unavailable}
    end
  end

  defp notice_status(store, identity) do
    case SupervisionStore.notice(store, identity) do
      {:ok, nil} -> :none
      {:ok, record} -> {:ok, metadata(record)}
      _ -> {:error, :store_unavailable}
    end
  end

  defp origin_target(session_key) do
    case SessionKey.parse(session_key) do
      # Hashed routing ids are not delivery targets; only a bound target with
      # retained provenance can address such a session.
      %{kind: :channel_peer} = parsed ->
        if SessionKey.opaque_routing?(parsed) do
          {:error, :opaque_session}
        else
          SupervisionNotice.target(%{
            channel_id: parsed.channel_id,
            account_id: parsed.account_id,
            peer: %{kind: parsed.peer_kind, id: parsed.peer_id, thread_id: parsed.thread_id}
          })
        end

      %{kind: :main} ->
        :none

      _ ->
        {:error, :invalid_session}
    end
  end

  defp valid_scope(run_id, session_key)
       when is_binary(run_id) and byte_size(run_id) in 1..256 and
              is_binary(session_key) and byte_size(session_key) in 1..2_048 do
    if String.valid?(run_id) and String.valid?(session_key),
      do: :ok,
      else: {:error, :invalid_scope}
  end

  defp valid_scope(_, _), do: {:error, :invalid_scope}

  defp admit_notice(store, target, {_, _, run_id, _} = identity, text) do
    with :ok <- matching_target(store, run_id, target),
         {:ok, existing} <- SupervisionStore.notice(store, identity) do
      case existing do
        nil ->
          record = %{
            identity: identity,
            target: target,
            text: text,
            delivery_state: :pending,
            attempts: 0,
            reason: nil,
            updated_at_ms: System.system_time(:millisecond)
          }

          case SupervisionStore.replace_notice(store, identity, nil, record) do
            :ok -> {:ok, record}
            {:error, :mismatch} -> existing_notice(store, target, identity, text)
            error -> error
          end

        %{target: ^target, text: ^text} = record ->
          {:ok, record}

        _ ->
          {:error, :notice_conflict}
      end
    end
  end

  defp existing_notice(store, target, identity, text) do
    case SupervisionStore.notice(store, identity) do
      {:ok, %{target: ^target, text: ^text} = record} -> {:ok, record}
      {:ok, _} -> {:error, :notice_conflict}
      _ -> {:error, :store_unavailable}
    end
  end

  defp matching_target(store, run_id, target) do
    case SupervisionStore.binding(store, run_id) do
      {:ok, nil} -> :ok
      {:ok, %{target: ^target}} -> :ok
      {:ok, _} -> {:error, :binding_conflict}
      _ -> {:error, :store_unavailable}
    end
  end

  defp call(server, message) do
    GenServer.call(server, message, @call_timeout)
  catch
    :exit, {:noproc, _} -> {:error, :supervision_unavailable}
    :exit, _ -> {:error, :outcome_unknown}
  end
end

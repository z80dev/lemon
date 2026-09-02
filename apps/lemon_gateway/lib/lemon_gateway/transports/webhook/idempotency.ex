defmodule LemonGateway.Transports.Webhook.Idempotency do
  @moduledoc """
  Idempotency-key reservation and response persistence for webhook submissions.
  """

  require Logger

  alias LemonCore.{Id, Store}
  alias LemonGateway.Transports.Webhook.Request

  @table :webhook_idempotency
  @response_table :webhook_idempotency_responses
  @reservation_lease_ms 60_000
  @response_retention_ms 86_400_000
  @sweep_interval_ms 60_000
  @last_sweep_key {__MODULE__, :last_response_sweep_ms}

  @spec table() :: atom()
  def table, do: @table

  @doc false
  def response_table, do: @response_table

  @doc false
  def sweep_expired(
        now_ms \\ System.system_time(:millisecond),
        retention_ms \\ @response_retention_ms
      )
      when is_integer(now_ms) and is_integer(retention_ms) and retention_ms >= 0 do
    cutoff_ms = now_ms - retention_ms

    @response_table
    |> Store.list()
    |> Enum.each(fn
      {{store_key, reservation_id} = receipt_key, receipt} when is_map(receipt) ->
        if Request.int_value(Request.fetch(receipt, :stored_at_ms), now_ms) <= cutoff_ms do
          sweep_response_receipt(store_key, reservation_id, receipt_key, receipt)
        end

      _ ->
        :ok
    end)

    @table
    |> Store.list()
    |> Enum.each(fn
      {store_key, entry} when is_map(entry) ->
        if Request.normalize_blank(Request.fetch(entry, :state)) == "completed" and
             Request.int_value(Request.fetch(entry, :updated_at_ms), now_ms) <= cutoff_ms do
          Store.compare_and_delete(@table, store_key, entry)
        end

      _ ->
        :ok
    end)

    :ok
  rescue
    _ -> {:error, :idempotency_unavailable}
  catch
    _, _ -> {:error, :idempotency_unavailable}
  end

  @spec context(Plug.Conn.t(), map(), binary(), map(), map()) ::
          {:ok, map() | nil} | {:duplicate, integer(), map()} | {:error, :idempotency_unavailable}
  def context(conn, _payload, integration_id, integration, webhook_config)
      when is_binary(integration_id) and is_map(integration) and is_map(webhook_config) do
    _ = maybe_sweep_expired()

    case resolve_idempotency_key(conn, integration, webhook_config) do
      nil ->
        {:ok, nil}

      idempotency_key ->
        store_key = store_key(integration_id, idempotency_key)

        case :global.trans({{__MODULE__, store_key}, self()}, fn ->
               reserve(store_key, integration_id, idempotency_key)
             end) do
          :aborted -> {:error, :idempotency_unavailable}
          {:aborted, _reason} -> {:error, :idempotency_unavailable}
          result -> result
        end
    end
  end

  @spec store_submission(map() | nil, binary(), binary(), atom() | binary()) ::
          :ok | {:error, :idempotency_unavailable}
  def store_submission(nil, _run_id, _session_key, _mode), do: :ok

  def store_submission(%{} = idempotency_ctx, run_id, session_key, mode) do
    merge_store_entry(idempotency_ctx, %{
      run_id: run_id,
      session_key: session_key,
      mode: normalize_mode(mode),
      idempotency_key: idempotency_ctx.idempotency_key,
      integration_id: idempotency_ctx.integration_id,
      state: "submitted",
      updated_at_ms: System.system_time(:millisecond)
    })
  end

  def store_submission(_ctx, _run_id, _session_key, _mode), do: :ok

  @doc "Persist an ambiguous submission without treating it as accepted."
  @spec store_outcome_unknown(map() | nil, binary(), binary(), atom() | binary()) ::
          :ok | {:error, :idempotency_unavailable}
  def store_outcome_unknown(nil, _run_id, _session_key, _mode), do: :ok

  def store_outcome_unknown(%{} = idempotency_ctx, run_id, session_key, mode) do
    merge_store_entry(idempotency_ctx, %{
      run_id: run_id,
      session_key: session_key,
      mode: normalize_mode(mode),
      idempotency_key: idempotency_ctx.idempotency_key,
      integration_id: idempotency_ctx.integration_id,
      state: "outcome_unknown",
      updated_at_ms: System.system_time(:millisecond)
    })
  end

  def store_outcome_unknown(_ctx, _run_id, _session_key, _mode), do: :ok

  @spec store_response(map() | nil, integer(), map()) ::
          :ok | {:error, :idempotency_unavailable}
  def store_response(nil, _status, _payload), do: :ok

  def store_response(%{} = idempotency_ctx, status, payload)
      when is_integer(status) and is_map(payload) do
    with :ok <- persist_response_receipt(idempotency_ctx, status, payload) do
      merge_store_entry(idempotency_ctx, %{
        response_status: status,
        response_payload: payload,
        state: "completed",
        updated_at_ms: System.system_time(:millisecond)
      })
    end
  end

  def store_response(_ctx, _status, _payload), do: :ok

  defp resolve_idempotency_key(conn, integration, webhook_config) do
    values = [idempotency_header(conn)]

    values =
      if allow_payload_idempotency_key?(integration, webhook_config) do
        values ++ [payload_idempotency_key(conn)]
      else
        values
      end

    first_non_blank(values)
  end

  defp idempotency_header(conn) do
    conn
    |> Plug.Conn.get_req_header("idempotency-key")
    |> List.first()
    |> Request.normalize_blank()
  end

  defp payload_idempotency_key(conn) do
    fetch_any(body_params(conn), [
      ["idempotency_key"],
      ["idempotencyKey"],
      ["idempotency", "key"]
    ])
  end

  defp body_params(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}
  defp body_params(%Plug.Conn{body_params: params}) when is_map(params), do: params
  defp body_params(_), do: %{}

  defp response(%{} = entry, store_key) do
    response_status = Request.int_value(Request.fetch(entry, :response_status), nil)
    response_payload = Request.fetch(entry, :response_payload)
    state = Request.normalize_blank(Request.fetch(entry, :state))

    cond do
      is_integer(response_status) and is_map(response_payload) ->
        {:duplicate, response_status, response_payload}

      true ->
        response_without_inline_receipt(entry, store_key, state)
    end
  end

  defp response_without_inline_receipt(entry, store_key, state) do
    mode = Request.normalize_blank(Request.fetch(entry, :mode))

    case fetch_response_receipt(entry, store_key) do
      {:ok, %{status: status, payload: payload}} ->
        {:duplicate, status, payload}

      {:error, :idempotency_unavailable} ->
        {:error, :idempotency_unavailable}

      {:ok, nil} when state == "pending" ->
        {:duplicate, 503,
         (fallback_payload(entry) || %{})
         |> Map.put(:status, "reservation_pending")
         |> Map.put(:retry_safe, true)}

      {:ok, nil} when state == "submitted" and mode == "sync" ->
        {:duplicate, 503,
         (fallback_payload(entry) || %{})
         |> Map.put(:status, "response_persistence_unknown")
         |> Map.put(:retry_safe, false)}

      {:ok, nil} ->
        case fallback_payload(entry) do
          %{} = payload -> {:duplicate, 202, payload}
          _ -> nil
        end
    end
  end

  defp persist_response_receipt(
         %{store_key: store_key, reservation_id: reservation_id},
         status,
         payload
       )
       when is_tuple(store_key) and is_binary(reservation_id) do
    with {:ok, %{} = existing} <- Store.fetch(@table, store_key),
         true <- Request.fetch(existing, :reservation_id) == reservation_id do
      receipt = %{
        status: status,
        payload: payload,
        stored_at_ms: System.system_time(:millisecond)
      }

      receipt_key = {store_key, reservation_id}

      case Store.put_new(@response_table, receipt_key, receipt) do
        :ok ->
          :ok

        {:error, :exists} ->
          case Store.fetch(@response_table, receipt_key) do
            {:ok, %{status: ^status, payload: ^payload}} -> :ok
            {:ok, _different} -> {:error, :idempotency_unavailable}
            {:error, _reason} -> {:error, :idempotency_unavailable}
          end

        {:error, _reason} ->
          {:error, :idempotency_unavailable}
      end
    else
      _ -> {:error, :idempotency_unavailable}
    end
  rescue
    _error -> {:error, :idempotency_unavailable}
  catch
    _kind, _reason -> {:error, :idempotency_unavailable}
  end

  defp persist_response_receipt(_ctx, _status, _payload),
    do: {:error, :idempotency_unavailable}

  defp fetch_response_receipt(entry, store_key) do
    case Request.normalize_blank(Request.fetch(entry, :reservation_id)) do
      reservation_id when is_binary(reservation_id) ->
        case Store.fetch(@response_table, {store_key, reservation_id}) do
          {:ok, %{status: status, payload: payload}}
          when is_integer(status) and is_map(payload) ->
            {:ok, %{status: status, payload: payload}}

          {:ok, nil} ->
            {:ok, nil}

          _ ->
            {:error, :idempotency_unavailable}
        end

      _ ->
        {:ok, nil}
    end
  rescue
    _error -> {:error, :idempotency_unavailable}
  catch
    _kind, _reason -> {:error, :idempotency_unavailable}
  end

  defp sweep_response_receipt(store_key, reservation_id, receipt_key, receipt) do
    case Store.fetch(@table, store_key) do
      {:ok, %{} = primary} ->
        if Request.fetch(primary, :reservation_id) == reservation_id do
          Store.compare_and_delete_many([
            {@table, store_key, primary},
            {@response_table, receipt_key, receipt}
          ])
        else
          Store.compare_and_delete(@response_table, receipt_key, receipt)
        end

      {:ok, nil} ->
        Store.compare_and_delete(@response_table, receipt_key, receipt)

      _ ->
        :ok
    end
  end

  defp maybe_sweep_expired do
    now_ms = System.system_time(:millisecond)
    last_ms = :persistent_term.get(@last_sweep_key, 0)

    if now_ms - last_ms >= @sweep_interval_ms do
      case :global.trans({{__MODULE__, :response_sweep}, self()}, fn ->
             current = :persistent_term.get(@last_sweep_key, 0)

             if now_ms - current >= @sweep_interval_ms do
               result = sweep_expired(now_ms, @response_retention_ms)
               :persistent_term.put(@last_sweep_key, now_ms)
               result
             else
               :ok
             end
           end) do
        :aborted -> :ok
        {:aborted, _} -> :ok
        result -> result
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp fallback_payload(entry) when is_map(entry) do
    run_id = Request.normalize_blank(Request.fetch(entry, :run_id))
    session_key = Request.normalize_blank(Request.fetch(entry, :session_key))
    state = Request.normalize_blank(Request.fetch(entry, :state))

    if is_binary(run_id) do
      %{run_id: run_id}
      |> maybe_put(:session_key, session_key)
      |> maybe_put(:mode, normalize_mode(Request.fetch(entry, :mode)))
      |> Map.merge(fallback_status(state))
    end
  end

  defp fallback_payload(_), do: nil

  defp merge_store_entry(%{store_key: store_key} = idempotency_ctx, entry)
       when is_tuple(store_key) and is_map(entry) do
    merge_store_entry(idempotency_ctx, entry, 3)
  rescue
    _error ->
      Logger.warning("webhook idempotency store write failed failure_class=exception")
      {:error, :idempotency_unavailable}
  end

  defp merge_store_entry(_ctx, _entry), do: :ok

  defp merge_store_entry(%{store_key: store_key} = idempotency_ctx, entry, attempts_left) do
    case Store.get(@table, store_key) do
      %{} = existing ->
        expected_reservation = Map.get(idempotency_ctx, :reservation_id)
        current_reservation = Request.fetch(existing, :reservation_id)

        if is_binary(expected_reservation) and current_reservation != expected_reservation do
          Logger.warning("webhook idempotency store write failed failure_class=stale_lease")
          {:error, :idempotency_unavailable}
        else
          replacement = Map.merge(existing, entry)

          case Store.compare_and_swap(@table, store_key, existing, replacement) do
            :ok ->
              :ok

            {:error, :mismatch} when attempts_left > 0 ->
              merge_store_entry(idempotency_ctx, entry, attempts_left - 1)

            {:error, _reason} ->
              Logger.warning("webhook idempotency store write failed failure_class=write_error")
              {:error, :idempotency_unavailable}

            _other ->
              Logger.warning(
                "webhook idempotency store write failed failure_class=unexpected_result"
              )

              {:error, :idempotency_unavailable}
          end
        end

      _ ->
        Logger.warning("webhook idempotency store write failed failure_class=missing_reservation")
        {:error, :idempotency_unavailable}
    end
  end

  defp reserve(store_key, integration_id, idempotency_key) do
    now_ms = System.system_time(:millisecond)
    reservation_id = Id.uuid7()

    entry = %{
      idempotency_key: idempotency_key,
      integration_id: integration_id,
      run_id: Id.run_id(),
      reservation_id: reservation_id,
      lease_expires_at_ms: now_ms + @reservation_lease_ms,
      state: "pending",
      updated_at_ms: now_ms
    }

    case Store.put_new(@table, store_key, entry) do
      :ok ->
        {:ok, reservation_context(entry, store_key)}

      {:error, :exists} ->
        resolve_existing_reservation(store_key, integration_id, idempotency_key, now_ms)

      {:error, _reason} ->
        Logger.warning("webhook idempotency reservation failed failure_class=write_error")
        {:error, :idempotency_unavailable}

      _other ->
        Logger.warning("webhook idempotency reservation failed failure_class=unexpected_result")
        {:error, :idempotency_unavailable}
    end
  rescue
    _error ->
      Logger.warning("webhook idempotency reservation failed failure_class=exception")
      {:error, :idempotency_unavailable}
  end

  defp resolve_existing_reservation(store_key, integration_id, idempotency_key, now_ms) do
    case Store.get(@table, store_key) do
      %{} = existing ->
        if reclaimable_pending?(existing, now_ms) do
          reclaim_pending(store_key, existing, integration_id, idempotency_key, now_ms)
        else
          case response(existing, store_key) do
            {:duplicate, _status, _payload} = duplicate -> duplicate
            _ -> {:error, :idempotency_unavailable}
          end
        end

      _ ->
        {:error, :idempotency_unavailable}
    end
  end

  defp reclaim_pending(store_key, existing, integration_id, idempotency_key, now_ms) do
    reservation_id = Id.uuid7()

    replacement =
      existing
      |> Map.put(
        :run_id,
        Request.normalize_blank(Request.fetch(existing, :run_id)) || Id.run_id()
      )
      |> Map.put(:reservation_id, reservation_id)
      |> Map.put(:lease_expires_at_ms, now_ms + @reservation_lease_ms)
      |> Map.put(:updated_at_ms, now_ms)

    case Store.compare_and_swap(@table, store_key, existing, replacement) do
      :ok ->
        {:ok,
         reservation_context(
           replacement,
           store_key,
           integration_id: integration_id,
           idempotency_key: idempotency_key
         )}

      {:error, :mismatch} ->
        resolve_existing_reservation(store_key, integration_id, idempotency_key, now_ms)

      {:error, _reason} ->
        {:error, :idempotency_unavailable}

      _other ->
        {:error, :idempotency_unavailable}
    end
  end

  defp reclaimable_pending?(entry, now_ms) do
    Request.normalize_blank(Request.fetch(entry, :state)) == "pending" and
      Request.int_value(Request.fetch(entry, :lease_expires_at_ms), 0) <= now_ms
  end

  defp reservation_context(entry, store_key, overrides \\ []) do
    %{
      integration_id:
        Keyword.get(overrides, :integration_id, Request.fetch(entry, :integration_id)),
      idempotency_key:
        Keyword.get(overrides, :idempotency_key, Request.fetch(entry, :idempotency_key)),
      store_key: store_key,
      run_id: Request.fetch(entry, :run_id),
      reservation_id: Request.fetch(entry, :reservation_id)
    }
  end

  defp store_key(integration_id, idempotency_key) do
    {to_string(integration_id), to_string(idempotency_key)}
  end

  defp allow_payload_idempotency_key?(integration, webhook_config) do
    [
      Request.fetch(integration, :allow_payload_idempotency_key),
      Request.fetch(webhook_config, :allow_payload_idempotency_key)
    ]
    |> Enum.find_value(false, &bool_value/1)
  end

  defp bool_value(value) when is_boolean(value), do: value
  defp bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  defp bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  defp bool_value(_), do: nil

  defp normalize_mode(mode) when mode in [:sync, :async], do: Atom.to_string(mode)
  defp normalize_mode(mode) when mode in ["sync", "async"], do: mode
  defp normalize_mode(_), do: nil

  defp fallback_status("outcome_unknown"),
    do: %{status: "outcome_unknown", retry_safe: false}

  defp fallback_status(_state), do: %{status: "accepted"}

  defp fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path -> fetch_path(map, path) end)
  end

  defp fetch_any(_, _), do: nil

  defp fetch_path(value, []), do: value

  defp fetch_path(value, [segment | rest]) do
    case Request.fetch(value, segment) do
      nil -> nil
      next -> fetch_path(next, rest)
    end
  end

  defp first_non_blank(values) do
    Enum.find_value(values, fn value ->
      case Request.normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

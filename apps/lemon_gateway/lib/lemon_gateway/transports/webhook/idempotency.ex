defmodule LemonGateway.Transports.Webhook.Idempotency do
  @moduledoc """
  Idempotency key management for webhook transport.

  Tracks webhook submissions by idempotency key to prevent duplicate
  processing. Keys are stored in `LemonCore.Store` and lifecycle through
  pending -> submitted -> completed states.
  """

  require Logger

  import LemonGateway.Transports.Webhook.Helpers
  alias LemonGateway.Transports.Webhook.Routing
  alias LemonCore.Store

  @idempotency_table :webhook_idempotency

  @doc """
  Returns the ETS table name used for idempotency storage.
  """
  @spec table() :: atom()
  def table, do: @idempotency_table

  @doc """
  Resolves the idempotency context for a request. Returns one of:
  - `{:ok, nil}` if no idempotency key is present
  - `{:ok, context}` for new idempotency keys (reserves the key)
  - `{:duplicate, status, payload}` for already-seen keys
  """
  @spec context(Plug.Conn.t(), map(), String.t(), map()) ::
          {:ok, map() | nil} | {:duplicate, integer(), map()}
  def context(conn, payload, integration_id, integration) do
    case resolve_idempotency_key(conn, payload, integration) do
      nil ->
        {:ok, nil}

      idempotency_key ->
        store_key = store_key(integration_id, idempotency_key)

        :global.trans({{__MODULE__, :idempotency, store_key}, self()}, fn ->
          case response(integration_id, idempotency_key) do
            {:duplicate, _status, _payload} = duplicate ->
              duplicate

            nil ->
              _ =
                Store.put(@idempotency_table, store_key, %{
                  idempotency_key: idempotency_key,
                  integration_id: integration_id,
                  state: "pending",
                  updated_at_ms: System.system_time(:millisecond)
                })

              {:ok,
               %{
                 integration_id: integration_id,
                 idempotency_key: idempotency_key,
                 store_key: store_key
               }}
          end
        end)
    end
  end

  @doc """
  Stores the submission metadata (run_id, session_key, mode) for an idempotency context.
  """
  @spec store_submission(map() | nil, String.t(), String.t(), atom()) :: :ok
  def store_submission(nil, _run_id, _session_key, _mode), do: :ok

  def store_submission(%{} = idempotency_ctx, run_id, session_key, mode) do
    entry =
      %{
        run_id: run_id,
        session_key: session_key,
        mode: Routing.normalize_mode_string(mode),
        idempotency_key: idempotency_ctx.idempotency_key,
        integration_id: idempotency_ctx.integration_id,
        state: "submitted",
        updated_at_ms: System.system_time(:millisecond)
      }

    merge_store_entry(idempotency_ctx, entry)
  end

  def store_submission(_idempotency_ctx, _run_id, _session_key, _mode), do: :ok

  @doc """
  Stores the final response for an idempotency context after completion.
  """
  @spec store_response(map() | nil, integer(), map()) :: :ok
  def store_response(nil, _status, _payload), do: :ok

  def store_response(%{} = idempotency_ctx, status, payload)
      when is_integer(status) and is_map(payload) do
    merge_store_entry(idempotency_ctx, %{
      response_status: status,
      response_payload: payload,
      state: "completed",
      updated_at_ms: System.system_time(:millisecond)
    })
  end

  def store_response(_idempotency_ctx, _status, _payload), do: :ok

  # --- Private helpers ---

  defp resolve_idempotency_key(conn, _payload, integration) do
    first_non_blank(
      [idempotency_header(conn)] ++
        optional_values(Routing.allow_payload_idempotency_key?(integration), [
          payload_idempotency_key(conn)
        ])
    )
  end

  defp optional_values(true, values) when is_list(values), do: values
  defp optional_values(_, _), do: []

  defp idempotency_header(conn) do
    conn
    |> Plug.Conn.get_req_header("idempotency-key")
    |> List.first()
    |> normalize_blank()
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

  defp response(integration_id, idempotency_key)
       when is_binary(integration_id) and is_binary(idempotency_key) do
    case Store.get(@idempotency_table, store_key(integration_id, idempotency_key)) do
      %{} = entry ->
        response_status = int_value(fetch(entry, :response_status), nil)
        response_payload = fetch(entry, :response_payload)
        state = normalize_blank(fetch(entry, :state))

        cond do
          is_integer(response_status) and is_map(response_payload) ->
            {:duplicate, response_status, response_payload}

          state == "pending" ->
            pending_response(entry)

          true ->
            fallback_response(entry)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp response(_, _), do: nil

  defp pending_response(entry) do
    pending_payload =
      case fallback_payload(entry) do
        %{} = payload -> Map.put_new(payload, :status, "processing")
        _ -> %{status: "processing"}
      end

    {:duplicate, 202, pending_payload}
  end

  defp fallback_response(entry) do
    case fallback_payload(entry) do
      %{} = payload -> {:duplicate, 202, payload}
      _ -> nil
    end
  end

  defp fallback_payload(entry) when is_map(entry) do
    run_id = normalize_blank(fetch(entry, :run_id))
    session_key = normalize_blank(fetch(entry, :session_key))

    if is_binary(run_id) and is_binary(session_key) do
      %{
        run_id: run_id,
        session_key: session_key
      }
      |> maybe_put(:mode, Routing.normalize_mode_string(fetch(entry, :mode)))
      |> maybe_put(:status, "accepted")
    end
  end

  defp fallback_payload(_), do: nil

  defp merge_store_entry(%{store_key: store_key} = idempotency_ctx, entry)
       when is_tuple(store_key) and is_map(entry) do
    merged_entry =
      case Store.get(@idempotency_table, store_key) do
        %{} = existing -> Map.merge(existing, entry)
        _ -> Map.merge(entry, %{idempotency_key: idempotency_ctx.idempotency_key})
      end

    case Store.put(@idempotency_table, store_key, merged_entry) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("webhook idempotency store write failed: #{inspect(reason)}")
        :ok

      other ->
        Logger.warning("webhook idempotency store returned unexpected result: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("webhook idempotency store failed: #{Exception.message(error)}")
      :ok
  end

  defp merge_store_entry(_idempotency_ctx, _entry), do: :ok

  defp store_key(integration_id, idempotency_key) do
    {to_string(integration_id), to_string(idempotency_key)}
  end
end

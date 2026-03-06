defmodule LemonGateway.Transports.Webhook.Idempotency do
  @moduledoc """
  Idempotency-key reservation and response persistence for webhook submissions.
  """

  require Logger

  alias LemonCore.Store
  alias LemonGateway.Transports.Webhook.Request

  @table :webhook_idempotency

  @spec table() :: atom()
  def table, do: @table

  @spec context(Plug.Conn.t(), map(), binary(), map(), map()) ::
          {:ok, map() | nil} | {:duplicate, integer(), map()}
  def context(conn, payload, integration_id, integration, webhook_config)
      when is_binary(integration_id) and is_map(integration) and is_map(webhook_config) do
    case resolve_idempotency_key(conn, integration, webhook_config) do
      nil ->
        {:ok, nil}

      idempotency_key ->
        store_key = store_key(integration_id, idempotency_key)

        :global.trans({{__MODULE__, store_key}, self()}, fn ->
          case response(integration_id, idempotency_key) do
            {:duplicate, _status, _payload} = duplicate ->
              duplicate

            nil ->
              _ =
                Store.put(@table, store_key, %{
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

  @spec store_submission(map() | nil, binary(), binary(), atom() | binary()) :: :ok
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

  defp response(integration_id, idempotency_key)
       when is_binary(integration_id) and is_binary(idempotency_key) do
    case Store.get(@table, store_key(integration_id, idempotency_key)) do
      %{} = entry ->
        response_status = Request.int_value(Request.fetch(entry, :response_status), nil)
        response_payload = Request.fetch(entry, :response_payload)
        state = Request.normalize_blank(Request.fetch(entry, :state))

        cond do
          is_integer(response_status) and is_map(response_payload) ->
            {:duplicate, response_status, response_payload}

          state == "pending" ->
            {:duplicate, 202, Map.put_new(fallback_payload(entry) || %{}, :status, "processing")}

          true ->
            case fallback_payload(entry) do
              %{} = payload -> {:duplicate, 202, payload}
              _ -> nil
            end
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp response(_, _), do: nil

  defp fallback_payload(entry) when is_map(entry) do
    run_id = Request.normalize_blank(Request.fetch(entry, :run_id))
    session_key = Request.normalize_blank(Request.fetch(entry, :session_key))

    if is_binary(run_id) and is_binary(session_key) do
      %{
        run_id: run_id,
        session_key: session_key
      }
      |> maybe_put(:mode, normalize_mode(Request.fetch(entry, :mode)))
      |> maybe_put(:status, "accepted")
    end
  end

  defp fallback_payload(_), do: nil

  defp merge_store_entry(%{store_key: store_key} = idempotency_ctx, entry)
       when is_tuple(store_key) and is_map(entry) do
    merged_entry =
      case Store.get(@table, store_key) do
        %{} = existing -> Map.merge(existing, entry)
        _ -> Map.merge(entry, %{idempotency_key: idempotency_ctx.idempotency_key})
      end

    case Store.put(@table, store_key, merged_entry) do
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

  defp merge_store_entry(_ctx, _entry), do: :ok

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

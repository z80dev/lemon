defmodule LemonChannels.Adapters.Email.Webhook do
  @moduledoc """
  Receives inbound email webhooks on `LemonChannels.InboundHttp`.

  Thin by design: authenticate, normalize, hand off. Provider-specific payload
  shapes are `LemonChannels.Adapters.Email`'s business and routing is the
  router's, so this only decides *whether* to accept a request and what status
  the provider sees.

  ## Authentication

  A shared token in the `x-webhook-token` header, compared in constant time:

      config :lemon_channels, LemonChannels.Adapters.Email, webhook_token: "..."

  With no token configured the endpoint **rejects everything** with 401 rather
  than running open. An inbound mail endpoint that accepts unauthenticated
  POSTs is a spam relay into someone's agent.

  ## Delivery receipts

  A normalized provider Message-ID is required, hashed before it is persisted,
  and also supplies a stable run reference. A request is rejected before router
  submission when its Message-ID is absent or the idempotency store is
  unavailable; an untracked provider retry must never create a second run.
  Router acceptance returns 202. A definite rejection marks that reservation
  eligible for the next attempt and returns 503 so redelivery is safe.
  An ambiguous mutation retains the reservation and returns 200 with
  `outcome unknown`: this is a successful provider receipt, not a claim that
  the router accepted the run, and prevents an automatic retry from creating a
  duplicate.

  The token is in a header rather than the body on purpose: that lets the check
  run as `c:LemonChannels.InboundHttp.Handler.authorized?/1`, which
  `LemonChannels.InboundHttp.Router` calls *before* parsing, so an
  unauthenticated caller cannot make the server decode a body — with
  attachments, the most expensive thing this endpoint does.

  `LemonChannels.Adapters.Email.Config` resolves the token, so the TOML
  `[gateway]` config's `email.webhook_token` (or `email.inbound.token`) is
  honoured too — an existing deployment does not have to re-issue its token to
  cut over. A malformed config yields no token, and therefore a 401: unreadable
  configuration must not fail open.
  """

  @behaviour LemonChannels.InboundHttp.Handler

  require Logger

  alias LemonChannels.Adapters.Email
  alias LemonChannels.Runtime
  alias LemonChannels.SubmissionOutcome
  alias LemonCore.Store

  @idempotency_table :email_inbound_idempotency
  @reservation_lease_ms 60_000

  @impl true
  def authorized?(conn) do
    case configured_token() do
      nil ->
        false

      token ->
        conn
        |> Plug.Conn.get_req_header("x-webhook-token")
        |> List.first()
        |> secure_equal?(token)
    end
  end

  @impl true
  def handle_inbound(conn) do
    # Re-checked rather than assumed. The router has already run `authorized?/1`
    # for anything arriving through it, but this stays correct for a handler
    # invoked directly, and the cost of the second check is one comparison.
    if authorized?(conn) do
      accept(conn)
    else
      Plug.Conn.send_resp(conn, 401, "unauthorized")
    end
  end

  defp accept(conn) do
    replay_content_identity = replay_content_identity(conn.body_params)

    case Email.normalize_inbound(conn.body_params) do
      {:ok, message} ->
        case reserve(message) do
          {:duplicate, receipt} -> duplicate_receipt(conn, receipt)
          {:new, reservation} -> handoff(conn, message, reservation, replay_content_identity)
          {:error, :missing_message_id} -> Plug.Conn.send_resp(conn, 400, "missing message id")
          {:error, :idempotency_unavailable} -> Plug.Conn.send_resp(conn, 503, "unavailable")
        end

      {:error, reason} ->
        Logger.warning("email webhook rejected payload: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 400, "bad request")
    end
  end

  defp handoff(conn, message, reservation, replay_content_identity) do
    case deliver_to_router(message, reservation, replay_content_identity) do
      :ok ->
        case remember(reservation, "accepted") do
          :ok ->
            # The provider's job is done only after both the router and the
            # durable replay receipt take responsibility for the message.
            Plug.Conn.send_resp(conn, 202, "accepted")

          {:error, :idempotency_unavailable} ->
            Plug.Conn.send_resp(conn, 503, "unavailable")
        end

      {:error, _} = error ->
        if SubmissionOutcome.uncertain?(error) do
          case remember(reservation, "outcome_unknown") do
            :ok ->
              Logger.error(
                "email webhook handoff outcome unknown; suppressing redelivery: reason=#{SubmissionOutcome.log_label(error)}"
              )

              Plug.Conn.send_resp(conn, 200, "outcome unknown")

            {:error, :idempotency_unavailable} ->
              Plug.Conn.send_resp(conn, 503, "unavailable")
          end
        else
          case release(reservation) do
            :ok ->
              Logger.error(
                "email webhook handoff rejected; asking for redelivery: reason=#{SubmissionOutcome.log_label(error)}"
              )

              Plug.Conn.send_resp(conn, 503, "unavailable")

            {:error, :idempotency_unavailable} ->
              Logger.error(
                "email webhook handoff rejected but reservation update failed; retry remains lease-gated"
              )

              Plug.Conn.send_resp(conn, 503, "unavailable")
          end
        end

      _unexpected ->
        case remember(reservation, "outcome_unknown") do
          :ok ->
            Logger.error(
              "email webhook handoff outcome unknown; suppressing redelivery: reason=unexpected_result"
            )

            Plug.Conn.send_resp(conn, 200, "outcome unknown")

          {:error, :idempotency_unavailable} ->
            Plug.Conn.send_resp(conn, 503, "unavailable")
        end
    end
  end

  defp reserve(%{message: %{id: message_id}}) when is_binary(message_id) and message_id != "" do
    store = store_module()
    digest = Base.encode16(:crypto.hash(:sha256, message_id), case: :lower)

    reservation = %{
      key: digest,
      run_id: "run_email_#{digest}",
      reservation_id: LemonCore.Id.uuid7()
    }

    entry = %{
      "run_id" => reservation.run_id,
      "reservation_id" => reservation.reservation_id,
      "state" => "pending",
      "updated_at_ms" => System.system_time(:millisecond),
      "lease_expires_at_ms" => System.system_time(:millisecond) + @reservation_lease_ms
    }

    case store.put_new(@idempotency_table, reservation.key, entry) do
      :ok ->
        {:new, reservation}

      {:error, :exists} ->
        reclaim_or_duplicate(reservation, entry)

      {:error, _reason} ->
        Logger.warning("email webhook idempotency unavailable failure_class=store_error")
        {:error, :idempotency_unavailable}

      _unexpected ->
        Logger.warning("email webhook idempotency unavailable failure_class=unexpected_result")
        {:error, :idempotency_unavailable}
    end
  rescue
    _error ->
      Logger.warning("email webhook idempotency unavailable failure_class=exception")
      {:error, :idempotency_unavailable}
  end

  defp reserve(_message), do: {:error, :missing_message_id}

  defp duplicate_receipt(conn, %{"state" => "accepted"}),
    do: Plug.Conn.send_resp(conn, 202, "accepted")

  defp duplicate_receipt(conn, %{"state" => "pending"}),
    do: Plug.Conn.send_resp(conn, 503, "delivery pending")

  defp duplicate_receipt(conn, _receipt),
    do: Plug.Conn.send_resp(conn, 200, "outcome unknown")

  defp remember(reservation, state),
    do: update_owned_reservation(reservation, %{"state" => state})

  defp release(reservation),
    do:
      update_owned_reservation(reservation, %{
        "state" => "rejected",
        "lease_expires_at_ms" => 0
      })

  defp update_owned_reservation(reservation, updates),
    do: update_owned_reservation(reservation, updates, 3)

  defp update_owned_reservation(_reservation, _updates, attempts_left)
       when attempts_left < 1,
       do: {:error, :idempotency_unavailable}

  defp update_owned_reservation(
         %{key: key, reservation_id: reservation_id} = reservation,
         updates,
         attempts_left
       ) do
    store = store_module()

    case store.get(@idempotency_table, key) do
      %{} = existing ->
        if (existing["reservation_id"] || existing[:reservation_id]) == reservation_id do
          replacement =
            existing
            |> Map.merge(updates)
            |> Map.put("updated_at_ms", System.system_time(:millisecond))

          case store.compare_and_swap(@idempotency_table, key, existing, replacement) do
            :ok ->
              :ok

            {:error, :mismatch} ->
              update_owned_reservation(reservation, updates, attempts_left - 1)

            _ ->
              {:error, :idempotency_unavailable}
          end
        else
          {:error, :idempotency_unavailable}
        end

      _ ->
        {:error, :idempotency_unavailable}
    end
  rescue
    _ -> {:error, :idempotency_unavailable}
  catch
    _, _ -> {:error, :idempotency_unavailable}
  end

  defp reclaim_or_duplicate(reservation, pending_entry) do
    store = store_module()

    case store.get(@idempotency_table, reservation.key) do
      %{} = existing ->
        state = existing["state"] || existing[:state]

        lease_expires_at_ms =
          existing["lease_expires_at_ms"] || existing[:lease_expires_at_ms] || 0

        if state == "rejected" or
             (state == "pending" and lease_expires_at_ms <= System.system_time(:millisecond)) do
          case store.compare_and_swap(
                 @idempotency_table,
                 reservation.key,
                 existing,
                 pending_entry
               ) do
            :ok -> {:new, reservation}
            {:error, :mismatch} -> reclaim_or_duplicate(reservation, pending_entry)
            {:error, _reason} -> {:error, :idempotency_unavailable}
            _unexpected -> {:error, :idempotency_unavailable}
          end
        else
          {:duplicate, existing}
        end

      _ ->
        {:error, :idempotency_unavailable}
    end
  rescue
    _ -> {:error, :idempotency_unavailable}
  catch
    _, _ -> {:error, :idempotency_unavailable}
  end

  # The runtime converts the message to the canonical RunRequest and crosses
  # RouterBridge.submit_run/1. A provider Message-ID supplies a stable run
  # reference so ambiguous submissions can be reconciled without inventing a
  # second identity.
  defp deliver_to_router(message, reservation, replay_content_identity),
    do:
      Runtime.submit_inbound(message,
        run_id: reservation.run_id,
        replay_identity: "email:" <> reservation.key,
        replay_content_identity: replay_content_identity
      )

  defp replay_content_identity(body_params) do
    body_params
    |> canonical_delivery_value()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_delivery_value(%Plug.Upload{} = upload) do
    %{
      filename: upload.filename,
      content_type: upload.content_type,
      content_sha256: file_digest(upload.path)
    }
  end

  defp canonical_delivery_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {key, canonical_delivery_value(item)} end)
    |> Map.new()
  end

  defp canonical_delivery_value(value) when is_list(value),
    do: Enum.map(value, &canonical_delivery_value/1)

  defp canonical_delivery_value(value), do: value

  defp file_digest(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      {:error, _reason} -> :unreadable
    end
  end

  defp file_digest(_path), do: :unreadable

  defp secure_equal?(nil, _token), do: false

  defp secure_equal?(given, token) when is_binary(given) do
    # Byte-size check first; :crypto.hash_equals/2 requires equal-length inputs.
    byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)
  end

  defp secure_equal?(_, _), do: false

  defp configured_token, do: Email.Config.webhook_token()

  defp store_module,
    do: Application.get_env(:lemon_channels, :email_webhook_store, Store)
end

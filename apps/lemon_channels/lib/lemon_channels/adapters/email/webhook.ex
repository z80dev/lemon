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

  A normalized provider Message-ID is hashed before it is persisted and also
  supplies a stable run reference. Router acceptance returns 202. A definite
  rejection releases that reservation and returns 503 so redelivery is safe.
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
    case Email.normalize_inbound(conn.body_params) do
      {:ok, message} ->
        case reserve(message) do
          {:duplicate, receipt} -> duplicate_receipt(conn, receipt)
          {:new, reservation} -> handoff(conn, message, reservation)
        end

      {:error, reason} ->
        Logger.warning("email webhook rejected payload: #{inspect(reason)}")
        Plug.Conn.send_resp(conn, 400, "bad request")
    end
  end

  defp handoff(conn, message, reservation) do
    case deliver_to_router(message, reservation.run_id) do
      :ok ->
        remember(reservation, "accepted")

        # The provider's job is done only after the router takes responsibility
        # for the message. The run itself remains asynchronous.
        Plug.Conn.send_resp(conn, 202, "accepted")

      {:error, _} = error ->
        if SubmissionOutcome.uncertain?(error) do
          remember(reservation, "outcome_unknown")

          Logger.error(
            "email webhook handoff outcome unknown; suppressing redelivery: reason=#{SubmissionOutcome.log_label(error)}"
          )

          Plug.Conn.send_resp(conn, 200, "outcome unknown")
        else
          release(reservation)

          Logger.error(
            "email webhook handoff rejected; asking for redelivery: reason=#{SubmissionOutcome.log_label(error)}"
          )

          Plug.Conn.send_resp(conn, 503, "unavailable")
        end

      _unexpected ->
        remember(reservation, "outcome_unknown")

        Logger.error(
          "email webhook handoff outcome unknown; suppressing redelivery: reason=unexpected_result"
        )

        Plug.Conn.send_resp(conn, 200, "outcome unknown")
    end
  end

  defp reserve(%{message: %{id: message_id}}) when is_binary(message_id) and message_id != "" do
    digest = Base.encode16(:crypto.hash(:sha256, message_id), case: :lower)
    reservation = %{key: digest, run_id: "run_email_#{digest}", tracked?: true}

    entry = %{
      "run_id" => reservation.run_id,
      "state" => "pending",
      "updated_at_ms" => System.system_time(:millisecond)
    }

    case Store.put_new(@idempotency_table, reservation.key, entry) do
      :ok ->
        {:new, reservation}

      {:error, :exists} ->
        {:duplicate, Store.get(@idempotency_table, reservation.key) || entry}

      {:error, _reason} ->
        Logger.warning("email webhook idempotency unavailable failure_class=store_error")
        {:new, %{reservation | tracked?: false}}

      _unexpected ->
        Logger.warning("email webhook idempotency unavailable failure_class=unexpected_result")
        {:new, %{reservation | tracked?: false}}
    end
  rescue
    _error ->
      Logger.warning("email webhook idempotency unavailable failure_class=exception")
      {:new, %{key: nil, run_id: nil, tracked?: false}}
  end

  defp reserve(_message), do: {:new, %{key: nil, run_id: nil, tracked?: false}}

  defp duplicate_receipt(conn, %{"state" => "accepted"}),
    do: Plug.Conn.send_resp(conn, 202, "accepted")

  defp duplicate_receipt(conn, _receipt),
    do: Plug.Conn.send_resp(conn, 200, "outcome unknown")

  defp remember(%{tracked?: true, key: key, run_id: run_id}, state) do
    case Store.put(@idempotency_table, key, %{
           "run_id" => run_id,
           "state" => state,
           "updated_at_ms" => System.system_time(:millisecond)
         }) do
      :ok -> :ok
      _ -> Logger.warning("email webhook idempotency update failed failure_class=store_error")
    end
  rescue
    _ -> Logger.warning("email webhook idempotency update failed failure_class=exception")
  end

  defp remember(_reservation, _state), do: :ok

  defp release(%{tracked?: true, key: key}) do
    case Store.delete(@idempotency_table, key) do
      :ok -> :ok
      _ -> Logger.warning("email webhook idempotency release failed failure_class=store_error")
    end
  rescue
    _ -> Logger.warning("email webhook idempotency release failed failure_class=exception")
  end

  defp release(_reservation), do: :ok

  # The runtime converts the message to the canonical RunRequest and crosses
  # RouterBridge.submit_run/1. A provider Message-ID supplies a stable run
  # reference so ambiguous submissions can be reconciled without inventing a
  # second identity.
  defp deliver_to_router(message, nil), do: Runtime.submit_inbound(message)

  defp deliver_to_router(message, run_id),
    do: Runtime.submit_inbound(message, run_id: run_id)

  defp secure_equal?(nil, _token), do: false

  defp secure_equal?(given, token) when is_binary(given) do
    # Byte-size check first; :crypto.hash_equals/2 requires equal-length inputs.
    byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)
  end

  defp secure_equal?(_, _), do: false

  defp configured_token, do: Email.Config.webhook_token()
end

defmodule LemonGateway.Transports.Webhook.InvocationDispatch do
  @moduledoc """
  Builds router submissions for webhook requests and dispatches them through RouterBridge.
  """

  alias LemonCore.RouterBridge
  alias LemonGateway.Transports.Webhook.{Idempotency, ResponseBuilder, Submission}

  @spec submit_run(Plug.Conn.t(), binary(), map(), map(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def submit_run(conn, integration_id, integration, payload, normalized, idempotency_ctx, opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    with {:ok, %{run_request: run_request, run_ctx: run_ctx}} <-
           Submission.build_submission(
             conn,
             integration_id,
             integration,
             payload,
             normalized,
             webhook_config: Keyword.fetch!(opts, :webhook_config),
             default_engine: Keyword.fetch!(opts, :default_engine),
             default_timeout_ms: Keyword.fetch!(opts, :default_timeout_ms),
             default_callback_wait_timeout_ms:
               Keyword.fetch!(opts, :default_callback_wait_timeout_ms),
             run_id: run_id,
             validate_callback_url: Keyword.fetch!(opts, :validate_callback_url),
             request_metadata_fun: Keyword.fetch!(opts, :request_metadata_fun)
           ),
         {:ok, wait_setup, callback_status} <-
           ResponseBuilder.prepare_wait_before_submit(
             run_ctx.mode,
             run_ctx,
             callback_waiter_ready_timeout_ms:
               Keyword.fetch!(opts, :callback_waiter_ready_timeout_ms)
           ) do
      perform_submit(
        run_request,
        Map.put(run_ctx, :callback_status, callback_status),
        wait_setup,
        idempotency_ctx
      )
    end
  end

  defp perform_submit(run_request, run_ctx, wait_setup, idempotency_ctx) do
    case RouterBridge.submit_run(run_request) do
      {:ok, submitted_run_id} when is_binary(submitted_run_id) ->
        Idempotency.store_submission(
          idempotency_ctx,
          submitted_run_id,
          run_ctx.session_key,
          run_ctx.mode
        )

        {:ok, run_ctx |> Map.merge(wait_setup) |> Map.put(:run_id, submitted_run_id)}

      {:error, reason} ->
        ResponseBuilder.cleanup_wait_setup(wait_setup)
        {:error, {:submit_failed, reason}}
    end
  rescue
    error ->
      ResponseBuilder.cleanup_wait_setup(wait_setup)
      {:error, {:submit_failed, Exception.message(error)}}
  end
end

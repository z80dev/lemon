defmodule LemonGateway.Transports.Webhook.ResponseBuilder do
  @moduledoc """
  Response shaping and callback wait orchestration for webhook runs.
  """

  alias LemonGateway.Transports.Webhook.Response

  @spec response_for_run(map(), keyword()) :: {:ok, non_neg_integer(), map()} | {:error, term()}
  def response_for_run(run_ctx, opts \\ []), do: Response.response_for_run(run_ctx, opts)

  @spec prepare_wait_before_submit(atom(), map(), keyword()) ::
          {:ok, map(), integer() | nil} | {:error, term()}
  def prepare_wait_before_submit(mode, run_ctx, opts \\ []) do
    Response.prepare_wait_before_submit(mode, run_ctx, opts)
  end

  @spec wait_for_run_completion(binary(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def wait_for_run_completion(run_id, timeout_ms) do
    Response.wait_for_run_completion(run_id, timeout_ms)
  end

  @spec callback_success_status?(term()) :: boolean()
  def callback_success_status?(status), do: Response.callback_success_status?(status)

  @spec cleanup_wait_setup(map()) :: :ok
  def cleanup_wait_setup(wait_setup), do: Response.cleanup_wait_setup(wait_setup)
end

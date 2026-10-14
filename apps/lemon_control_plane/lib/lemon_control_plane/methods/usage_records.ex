defmodule LemonControlPlane.Methods.UsageRecords do
  @moduledoc "Read-only canonical native usage ledger, with filter-bound pagination."
  @behaviour LemonControlPlane.Method
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "usage.records"
  @impl true
  def scopes, do: [:read]
  @impl true
  def handle(params, _ctx) do
    case LemonCore.UsageStore.records(params) do
      {:ok, page} ->
        {:ok,
         %{
           "records" => Enum.map(page.records, &wire/1),
           "nextCursor" => page.next_cursor,
           "incomplete" => page.incomplete
         }}

      {:error, reason} when reason in [:invalid_usage_filters, :invalid_usage_cursor] ->
        {:error, Errors.error(:invalid_request, "Invalid usage range, filters or cursor")}

      {:error, _} ->
        {:error, Errors.error(:unavailable, "Usage ledger unavailable")}
    end
  end

  defp wire(record) do
    %{
      "id" => record.id,
      "runId" => record.run_id,
      "sessionKey" => record.session_key,
      "agentId" => record.agent_id,
      "atMs" => record.at_ms,
      "model" => record.model,
      "provider" => record.provider,
      "inputTokens" => record.input_tokens,
      "outputTokens" => record.output_tokens,
      "totalTokens" => record.total_tokens,
      "costUsd" => record.cost_usd,
      "priceKnown" => record.price_known
    }
  end
end

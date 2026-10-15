defmodule LemonControlPlane.Methods.RunsReceiptGet do
  @moduledoc "Read a router admission receipt by its fixed intent ID without dispatch."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.{ChatSubmission, Protocol.Errors}

  @impl true
  def name, do: "runs.receipt.get"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with true <- Map.has_key?(params, "runId"),
         true <- is_boolean(Map.get(params, "includeAnswer", false)),
         {:ok, run_id} <- ChatSubmission.run_id(params) do
      case LemonCore.RouterBridge.run_receipt(run_id) do
        {:ok, receipt} -> {:ok, %{"receipt" => ChatSubmission.project(receipt)}}
        {:error, :not_found} -> {:error, Errors.error(:not_found, "Run receipt not found")}
        _ -> {:error, Errors.error(:unavailable, "Run receipt is unavailable")}
      end
    else
      false ->
        {:error, Errors.invalid_request("runId is required and includeAnswer must be a boolean")}

      error ->
        error
    end
  end
end

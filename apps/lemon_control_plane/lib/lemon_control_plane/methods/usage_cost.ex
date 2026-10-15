defmodule LemonControlPlane.Methods.UsageCost do
  @moduledoc """
  Read-only usage.cost projection of the shared usage ledger.

  See `LemonCore.UsageReport` for the bounded, known-cost report contract.
  """
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.UsageReport

  @impl true
  def name, do: "usage.cost"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    case UsageReport.query(params) do
      {:ok, result} ->
        {:ok, result}

      {:error, _} ->
        {:error, Errors.error(:unavailable, "Usage ledger unavailable")}
    end
  end
end

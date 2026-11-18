defmodule LemonControlPlane.Methods.SmsInboxClear do
  @moduledoc """
  Handler for `sms.inbox.clear`: operator force-clear of the shared SMS inbox
  reservation, preview first and confirmation-bound to the exact holder.

  Without `confirmToken` (or with `dryRun: true`) it previews the current holder
  and returns a single-use token kept server-side by the inbox. With `holder`
  and `confirmToken` it clears the reservation only if that holder and lease are
  unchanged since the preview. After a clear the number is free at once; a late
  text for the previous holder arriving after another session reserves goes to
  that session.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.EngineInfoBridge

  @impl true
  def name, do: "sms.inbox.clear"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with :ok <- validate(params) do
      if Map.get(params, "dryRun", false) or is_nil(params["confirmToken"]) do
        preview()
      else
        confirm(params["holder"], params["confirmToken"])
      end
    end
  end

  defp validate(params) when is_map(params) do
    cond do
      not is_boolean(Map.get(params, "dryRun", false)) ->
        {:error, {:invalid_params, "dryRun must be a boolean", nil}}

      not is_nil(params["confirmToken"]) and not is_binary(params["confirmToken"]) ->
        {:error, {:invalid_params, "confirmToken must be a string", nil}}

      is_binary(params["confirmToken"]) and not is_binary(params["holder"]) ->
        {:error, {:invalid_params, "holder is required with confirmToken", nil}}

      true ->
        :ok
    end
  end

  defp validate(_params), do: {:error, {:invalid_params, "Expected clear parameters", nil}}

  defp preview do
    case EngineInfoBridge.sms_inbox_preview_clear() do
      {:ok, %{holder: holder, released: released, confirm_token: token}} ->
        {:ok,
         %{"dryRun" => true, "holder" => holder, "released" => released, "confirmToken" => token}}

      {:error, reason} ->
        unavailable(reason)
    end
  end

  defp confirm(holder, token) do
    case EngineInfoBridge.sms_inbox_confirm_clear(holder, token) do
      :ok ->
        {:ok, %{"dryRun" => false, "holder" => holder, "cleared" => true}}

      {:error, :confirmation_required} ->
        {:error,
         {:conflict, "Run a preview and provide its exact holder and confirmToken",
          %{"reason" => "confirmation_required"}}}

      {:error, :confirmation_mismatch} ->
        {:error,
         {:conflict, "The reservation changed since the preview; run a new preview",
          %{"reason" => "confirmation_mismatch"}}}

      {:error, :outcome_unknown} ->
        {:error,
         {:unavailable, "The clear may have been applied; run a preview to check",
          %{"reason" => "outcome_unknown", "retrySafe" => false}}}

      {:error, reason} ->
        unavailable(reason)
    end
  end

  defp unavailable(_reason),
    do:
      {:error,
       {:unavailable, "The SMS inbox is not running or its store is unavailable",
        %{"reason" => "sms_inbox_unavailable"}}}
end

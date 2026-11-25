defmodule LemonControlPlane.Methods.SessionsReset do
  @moduledoc """
  Handler for the sessions.reset method.

  Preview-first, confirmation-bound conversation reset through
  `LemonControlPlane.SessionLifecycle.reset/2`.

  Without `confirmToken` (or with `dryRun: true`) this mutates nothing and
  returns a redacted preview digest plus a single-use server-side
  `confirmToken`. Confirmed resets (`dryRun: false` with `confirmToken`) run
  under the session's run-admission fence
  (`LemonControlPlane.Methods.SessionLifecycleFence`). Success is reported only
  after every deletion is verified.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SessionLifecycleFence
  alias LemonControlPlane.SessionLifecycle

  @impl true
  def name, do: "sessions.reset"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with {:ok, session_key, dry_run?, confirm_token} <- validate(params) do
      if dry_run? do
        handle_preview(session_key)
      else
        handle_confirm(session_key, confirm_token)
      end
    end
  end

  defp validate(params) when is_map(params) do
    session_key = params["sessionKey"]
    confirm_token = params["confirmToken"]

    dry_run? =
      case Map.fetch(params, "dryRun") do
        {:ok, value} -> value
        :error -> is_nil(confirm_token)
      end

    cond do
      not is_binary(session_key) or session_key == "" ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      not is_boolean(dry_run?) ->
        {:error, {:invalid_params, "dryRun must be a boolean", nil}}

      not is_nil(confirm_token) and not is_binary(confirm_token) ->
        {:error, {:invalid_params, "confirmToken must be a string", nil}}

      true ->
        {:ok, session_key, dry_run?, confirm_token}
    end
  end

  defp validate(_params), do: {:error, {:invalid_request, "sessionKey is required", nil}}

  defp handle_preview(session_key) do
    case safe_preview(session_key) do
      {:ok, preview} ->
        {:ok, preview_summary(preview)}

      {:error, _reason} ->
        {:error,
         {:unavailable, "Session reset preview is unavailable; no session reset was applied",
          %{
            "reason" => "unavailable",
            "retrySafe" => false,
            "mutationMayHaveApplied" => false
          }}}
    end
  end

  defp safe_preview(session_key) do
    SessionLifecycle.reset(session_key, dry_run: true)
  rescue
    _ -> {:error, :session_store_unavailable}
  catch
    _kind, _reason -> {:error, :session_store_unavailable}
  end

  defp handle_confirm(_session_key, token) when not is_binary(token) or token == "" do
    {:error,
     {:conflict, "Run a dry-run preview and provide its confirmToken",
      %{
        "reason" => "confirmation_required",
        "retrySafe" => false,
        "mutationMayHaveApplied" => false
      }}}
  end

  defp handle_confirm(session_key, confirm_token) do
    reset = fn generation ->
      SessionLifecycle.reset(session_key,
        dry_run: false,
        confirm_token: confirm_token,
        fence_generation: generation
      )
    end

    case SessionLifecycleFence.run(session_key, :reset, reset) do
      {:ok, %{verified: true} = result} ->
        {:ok, applied_summary(result)}

      {:error, :confirmation_required} ->
        {:error,
         {:conflict, "Run a dry-run preview and provide its confirmToken",
          %{
            "reason" => "confirmation_required",
            "retrySafe" => false,
            "mutationMayHaveApplied" => false
          }}}

      {:error, :confirmation_mismatch} ->
        {:error,
         {:conflict, "Session state changed or preview token is invalid; run a new preview",
          %{
            "reason" => "confirmation_mismatch",
            "retrySafe" => false,
            "mutationMayHaveApplied" => false
          }}}

      {:error, :session_store_unavailable} ->
        {:error,
         {:unavailable, "Session store is unavailable; no session reset was applied",
          %{
            "reason" => "unavailable",
            "retrySafe" => false,
            "mutationMayHaveApplied" => false
          }}}

      {:error, reason} ->
        SessionLifecycleFence.failure(reason, "reset")

      _unexpected ->
        SessionLifecycleFence.failure(:outcome_unknown, "reset")
    end
  end

  defp preview_summary(preview) do
    %{
      "dryRun" => true,
      "success" => true,
      "sessionKey" => preview.session_key,
      "confirmToken" => preview.confirm_token,
      "digest" => preview.digest,
      "preview" => %{
        "sessionKey" => preview.session_key,
        "digest" => preview.digest,
        "runHistoryCount" => preview.run_history_count,
        "hasChatState" => preview.has_chat_state,
        "hasSessionPolicy" => preview.has_session_policy,
        "hasAcpMetadata" => preview.has_acp_metadata,
        "hasAcpRunState" => preview.has_acp_run_state
      },
      "summary" => %{
        "sessionKey" => preview.session_key,
        "reset" => false,
        "verified" => false,
        "requiresConfirmation" => true,
        "cleanup" => %{
          "deletedRunHistory" => false,
          "deletedChatState" => false,
          "deletedSessionPolicy" => false,
          "includesMessages" => false,
          "includesPolicy" => false,
          "includesSecretValues" => false
        }
      }
    }
  end

  defp applied_summary(result) do
    %{
      "dryRun" => false,
      "success" => true,
      "sessionKey" => result.session_key,
      "digest" => result.digest,
      "summary" => %{
        "sessionKey" => result.session_key,
        "reset" => true,
        "verified" => true,
        "cleanup" => %{
          "deletedRunHistory" => true,
          "deletedChatState" => true,
          "deletedSessionPolicy" => true,
          "includesMessages" => false,
          "includesPolicy" => false,
          "includesSecretValues" => false
        }
      }
    }
  end
end

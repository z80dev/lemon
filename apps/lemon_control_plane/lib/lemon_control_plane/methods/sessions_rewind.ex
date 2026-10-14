defmodule LemonControlPlane.Methods.SessionsRewind do
  @moduledoc "Previews and confirms native session rewinds."
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.rewind"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, entry_id} <- NativeSessions.string(params, "entryId", 256),
         {:ok, restore_files} <- NativeSessions.boolean(params, "restoreFiles", false),
         {:ok, allow_partial} <- NativeSessions.boolean(params, "allowPartialRestore", false),
         :ok <- validate_restore_intent(restore_files, allow_partial),
         {:ok, dry_run} <- NativeSessions.boolean(params, "dryRun", true),
         {:ok, token} <- confirmation(params, dry_run) do
      opts = [
        restore_files: restore_files,
        allow_partial_restore: allow_partial,
        dry_run: dry_run,
        confirmation_token: token
      ]

      fallback = if dry_run, do: :unavailable, else: :outcome_unknown

      case AgentRuntime.call(:session_rewind, [key, cwd, entry_id, opts], {:error, fallback}) do
        {:ok, result} when is_map(result) ->
          fields =
            if dry_run,
              do:
                ~w(confirmationToken prompt promptContainsNonText discardedMessages restorePaths unrestorableTools unrestorableCommands unrestorableCommandCount canAllowPartialRestore restoreFiles allowPartialRestore entryId sessionId),
              else:
                ~w(confirmationToken prompt leafId restoredPaths unrestorableTools unrestorableCommands unrestorableCommandCount canAllowPartialRestore restoreFiles allowPartialRestore partialRestore entryId sessionId)

          {:ok, result |> Map.take(fields) |> Map.put("sessionKey", key)}

        {:error, reason} ->
          NativeSessions.failure(reason)

        _ ->
          NativeSessions.failure(if dry_run, do: :invalid_response, else: :outcome_unknown)
      end
    end
  end

  defp validate_restore_intent(false, true),
    do: NativeSessions.invalid("allowPartialRestore requires restoreFiles")

  defp validate_restore_intent(_restore_files, _allow_partial), do: :ok

  defp confirmation(params, dry_run) do
    if Map.has_key?(params, "confirmationToken") do
      NativeSessions.string(params, "confirmationToken", 256)
    else
      if dry_run, do: {:ok, nil}, else: NativeSessions.failure(:confirmation_required)
    end
  end
end

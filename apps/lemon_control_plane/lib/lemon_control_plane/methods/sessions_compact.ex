defmodule LemonControlPlane.Methods.SessionsCompact do
  @moduledoc """
  Handler for the sessions.compact method.

  Triggers manual context compaction for a live or durable native session.
  Optional `cwd` locates a durable session; `focus` becomes native summary
  instructions, while `summary` remains an explicit replacement summary.
  Manual requests default `force` to true. Receipts never contain summary text.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @impl true
  def name, do: "sessions.compact"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, _ctx) when is_map(params) do
    with {:ok, session_key} <- NativeSessions.string(params, "sessionKey", 1024),
         {:ok, force} <- NativeSessions.boolean(params, "force", true),
         {:ok, cwd} <- optional_string(params, "cwd", 4096),
         {:ok, focus} <- optional_string(params, "focus", 16_384),
         {:ok, custom_summary} <- optional_string(params, "summary", 131_072) do
      opts =
        [force: force]
        |> put_optional(:cwd, cwd)
        |> put_optional(:custom_instructions, focus)
        |> put_optional(:summary, custom_summary)

      case compact_session(session_key, opts) do
        :ok ->
          {:ok,
           %{
             "success" => true,
             "sessionKey" => session_key,
             "tokensBefore" => nil,
             "tokensAfter" => nil,
             "summary" => summary(session_key, opts)
           }}

        {:error, :session_registry_not_available} ->
          {:error,
           {:internal_error, "Failed to compact session", :session_registry_not_available}}

        {:error, reason} ->
          NativeSessions.failure(reason)
      end
    end
  end

  def handle(_, _), do: NativeSessions.invalid("params must be an object")

  defp optional_string(params, field, max) do
    if Map.has_key?(params, field) do
      NativeSessions.string(params, field, max)
    else
      {:ok, nil}
    end
  end

  defp put_optional(opts, _key, nil), do: opts
  defp put_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp compact_session(session_key, opts) do
    case AgentRuntime.mutate(:compact_session, [session_key, opts]) do
      :ok -> :ok
      {:error, :unavailable} -> {:error, :session_registry_not_available}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :outcome_unknown}
    end
  end

  defp summary(session_key, opts) do
    %{
      "sessionKeyReturned" => is_binary(session_key) and session_key != "",
      "compacted" => true,
      "force" => Keyword.fetch!(opts, :force),
      "customSummaryProvided" => Keyword.has_key?(opts, :summary),
      "focusProvided" => Keyword.has_key?(opts, :custom_instructions),
      "tokensBeforeReturned" => false,
      "tokensAfterReturned" => false,
      "cleanup" => %{
        "includesPromptText" => false,
        "includesSummaryText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end

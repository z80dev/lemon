defmodule LemonControlPlane.Methods.SessionsLabel do
  @moduledoc """
  Sets or clears the bookmark label of a native session tree entry.

  Labels are bounded single-line text; control characters and whitespace runs become
  one space. `null` (or text that is empty once sanitized) clears the label.
  """
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @max_label_chars 120

  @impl true
  def name, do: "sessions.label"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, entry_id} <- NativeSessions.string(params, "entryId", 256),
         {:ok, label} <- label(params) do
      case AgentRuntime.call(
             :session_label,
             [key, cwd, entry_id, label],
             {:error, :unavailable}
           ) do
        {:ok, result} when is_map(result) ->
          {:ok,
           result
           |> Map.take(~w(sessionId entryId label))
           |> Map.put("sessionKey", key)}

        {:error, reason} ->
          NativeSessions.failure(reason)

        _ ->
          NativeSessions.failure(:invalid_response)
      end
    end
  end

  defp label(%{"label" => nil}), do: {:ok, nil}

  defp label(%{"label" => text}) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        NativeSessions.invalid("label must be valid UTF-8")

      String.length(text) > @max_label_chars * 4 ->
        too_long()

      true ->
        case text |> String.replace(~r/[\p{Cc}\p{Cf}\s]+/u, " ") |> String.trim() do
          "" ->
            {:ok, nil}

          clean ->
            if String.length(clean) > @max_label_chars, do: too_long(), else: {:ok, clean}
        end
    end
  end

  defp label(_), do: NativeSessions.invalid("label must be a string or null")

  defp too_long,
    do: NativeSessions.invalid("label must be at most #{@max_label_chars} characters")
end

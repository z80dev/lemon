defmodule CodingAgent.ExecutionNode.ConnectFailure do
  @moduledoc "Classifies bounded connect failures without exposing server messages or credentials."

  @reasons ~w(session_expired session_invalid node_not_found node_name_conflict)

  @spec classify(term()) :: :transient | {:needs_reauthorization | :conflict, String.t()}
  def classify(%{"code" => code} = error) do
    case code do
      code when code in ["UNAUTHORIZED", "FORBIDDEN", "NOT_FOUND"] ->
        {:needs_reauthorization, reason(error, "credential_rejected")}

      "CONFLICT" ->
        {:conflict, reason(error, "conflict")}

      _ ->
        :transient
    end
  end

  def classify(_), do: :transient

  defp reason(%{"details" => %{"reason" => reason}}, _) when reason in @reasons,
    do: reason

  defp reason(_, fallback), do: fallback
end

defmodule LemonRouter.ConversationKey do
  @moduledoc """
  Canonical conversation key selection for router-owned queue coordination.

  Priority:
  1) explicit/auto-resolved resume token
  2) raw session key
  """

  alias LemonCore.ResumeToken

  @type t :: {:resume, binary(), binary()} | {:session, binary()}

  @spec resolve(binary() | nil, ResumeToken.t() | map() | nil) :: t()
  def resolve(session_key, resume) do
    case normalize_resume(resume) do
      %ResumeToken{engine: engine, value: value} ->
        {:resume, engine, value}

      _ ->
        {:session, normalize_session_key(session_key)}
    end
  end

  @spec from_submission(map()) :: t()
  def from_submission(submission) when is_map(submission) do
    resolve(fetch(submission, :session_key), fetch(submission, :resume))
  end

  @spec to_string_key(t()) :: binary()
  def to_string_key({:resume, engine, value}) when is_binary(engine) and is_binary(value),
    do: "resume:" <> engine <> ":" <> value

  def to_string_key({:session, session_key}) when is_binary(session_key),
    do: "session:" <> session_key

  defp normalize_resume(%ResumeToken{} = resume), do: resume

  defp normalize_resume(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume(_), do: nil

  defp normalize_session_key(session_key) when is_binary(session_key) and session_key != "",
    do: session_key

  defp normalize_session_key(_), do: "default"

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

defmodule LemonRouter.ResumeResolver do
  @moduledoc """
  Router-owned resume resolution.

  This module resolves the effective resume token before gateway submission,
  moving auto-resume semantics out of gateway scheduler mutation.
  """

  alias LemonCore.ResumeToken

  @type resolved :: {ResumeToken.t() | nil, binary() | nil}

  @spec resolve(ResumeToken.t() | map() | nil, binary() | nil, binary() | nil, map()) :: resolved()
  def resolve(explicit_resume, session_key, selected_engine_id, meta \\ %{}) do
    cond do
      (resume = normalize_resume(explicit_resume)) != nil ->
        {resume, selected_engine_id || resume.engine}

      disable_auto_resume?(meta) ->
        {nil, selected_engine_id}

      true ->
        resolve_auto_resume(session_key, selected_engine_id)
    end
  end

  defp resolve_auto_resume(session_key, selected_engine_id) when is_binary(session_key) do
    case LemonCore.ChatStateStore.get(session_key) do
      %LemonGateway.ChatState{last_engine: engine, last_resume_token: token}
      when is_binary(engine) and is_binary(token) ->
        apply_auto_resume_if_compatible(engine, token, selected_engine_id)

      %{} = state ->
        engine = fetch(state, :last_engine)
        token = fetch(state, :last_resume_token)

        if is_binary(engine) and is_binary(token) do
          apply_auto_resume_if_compatible(engine, token, selected_engine_id)
        else
          {nil, selected_engine_id}
        end

      _ ->
        {nil, selected_engine_id}
    end
  rescue
    _ -> {nil, selected_engine_id}
  end

  defp resolve_auto_resume(_session_key, selected_engine_id), do: {nil, selected_engine_id}

  defp apply_auto_resume_if_compatible(engine, token, selected_engine_id) do
    if compatible_engine?(selected_engine_id, engine) do
      resume = %ResumeToken{engine: engine, value: token}
      {resume, selected_engine_id || engine}
    else
      {nil, selected_engine_id}
    end
  end

  defp compatible_engine?(nil, _engine), do: true
  defp compatible_engine?(engine, engine), do: true

  defp compatible_engine?(selected_engine, engine)
       when is_binary(selected_engine) and is_binary(engine) do
    selected_engine == engine || String.split(selected_engine, ":", parts: 2) |> List.first() == engine
  end

  defp compatible_engine?(_selected_engine, _engine), do: false

  defp disable_auto_resume?(meta) when is_map(meta) do
    fetch(meta, :disable_auto_resume) == true
  end

  defp disable_auto_resume?(_), do: false

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

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

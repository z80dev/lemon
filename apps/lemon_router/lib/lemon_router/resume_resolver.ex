defmodule LemonRouter.ResumeResolver do
  @moduledoc """
  Router-owned native resume resolution.

  Explicit resume tokens must belong to Lemon. Persisted tokens from retired
  engines are left in chat state for rollback/history, but never resumed.
  """

  require Logger

  alias LemonCore.ResumeToken

  @native_engine "lemon"

  @type source :: :explicit | :auto | nil
  @type resolved ::
          {:ok, ResumeToken.t() | nil, source()}
          | {:error, {:unsupported_resume_engine, binary(), String.t()}}

  @spec resolve(ResumeToken.t() | map() | nil, binary() | nil, map()) :: resolved()
  def resolve(explicit_resume, session_key, meta \\ %{}) do
    case normalize_explicit_resume(explicit_resume) do
      {:ok, resume} ->
        {:ok, resume, :explicit}

      {:error, engine} ->
        {:error,
         {:unsupported_resume_engine, engine,
          "Top-level router resumes support only the native \"lemon\" engine. " <>
            "Use `lemon resume <id>` or omit the resume token."}}

      :none ->
        if disable_auto_resume?(meta) do
          {:ok, nil, nil}
        else
          resolve_auto_resume(session_key)
        end
    end
  end

  defp resolve_auto_resume(session_key) when is_binary(session_key) do
    case persisted_resume(LemonCore.ChatStateStore.get(session_key)) do
      {:native, resume} ->
        {:ok, resume, :auto}

      {:non_native, engine} ->
        Logger.warning(
          "Router ignored persisted non-native resume state session=#{inspect(session_key)} " <>
            "engine=#{inspect(engine)}"
        )

        {:ok, nil, nil}

      :none ->
        {:ok, nil, nil}
    end
  rescue
    _ -> {:ok, nil, nil}
  end

  defp resolve_auto_resume(_session_key), do: {:ok, nil, nil}

  defp persisted_resume(state) when is_map(state) do
    case {fetch(state, :last_engine), fetch(state, :last_resume_token)} do
      {engine, token} when is_binary(engine) and is_binary(token) ->
        case normalize_engine(engine) do
          @native_engine -> {:native, %ResumeToken{engine: @native_engine, value: token}}
          nil -> :none
          other -> {:non_native, other}
        end

      _ ->
        :none
    end
  end

  defp persisted_resume(_), do: :none

  defp normalize_explicit_resume(%ResumeToken{engine: engine, value: value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(%{engine: engine, value: value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(%{"engine" => engine, "value" => value}),
    do: normalize_explicit_token(engine, value)

  defp normalize_explicit_resume(_), do: :none

  defp normalize_explicit_token(engine, value) when is_binary(engine) do
    case normalize_engine(engine) do
      @native_engine when is_binary(value) ->
        {:ok, %ResumeToken{engine: @native_engine, value: value}}

      @native_engine ->
        :none

      nil ->
        :none

      other ->
        {:error, other}
    end
  end

  defp normalize_explicit_token(_engine, _value), do: :none

  defp normalize_engine(engine) when is_binary(engine) do
    case String.trim(engine) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_engine(_), do: nil

  defp disable_auto_resume?(meta) when is_map(meta) do
    fetch(meta, :disable_auto_resume) == true
  end

  defp disable_auto_resume?(_), do: false

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

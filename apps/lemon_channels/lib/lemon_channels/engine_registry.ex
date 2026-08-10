defmodule LemonChannels.EngineRegistry do
  @moduledoc """
  Temporary compatibility parser for resume lines.

  Validation and formatting belong in `LemonCore.EngineCatalog` and
  `LemonCore.ResumeToken`. This module remains only because engine-runtime
  engines may expose additional resume syntax, which we ask for through
  `LemonCore.EngineInfoBridge` rather than by reaching into the gateway.
  """

  alias LemonCore.{EngineCatalog, EngineInfoBridge, ResumeToken}

  @spec extract_resume(String.t()) :: {:ok, ResumeToken.t()} | :none
  def extract_resume(text) when is_binary(text) do
    case safe_gateway_extract_resume(text) do
      {:ok, %ResumeToken{} = token} -> {:ok, token}
      _ -> parse_resume_line(text)
    end
  rescue
    _ -> :none
  end

  def extract_resume(_), do: :none

  defp safe_gateway_extract_resume(text), do: EngineInfoBridge.extract_resume(text)

  defp parse_resume_line(text) when is_binary(text) do
    stripped = text |> String.trim() |> String.trim("`")

    if stripped == "" do
      :none
    else
      lines = String.split(stripped, "\n", trim: true)

      Enum.find_value(lines, :none, fn line ->
        case parse_resume_regex(String.trim(line)) do
          {:ok, _} = ok -> ok
          _ -> nil
        end
      end) || :none
    end
  end

  defp parse_resume_regex(text) do
    cond do
      match = Regex.run(~r/^(?:claude)\s+--resume\s+([^\s`]+)$/i, text) ->
        [_, value] = match
        {:ok, %ResumeToken{engine: "claude", value: value}}

      match = Regex.run(~r/^([a-z0-9_-]+)\s+resume\s+([^\s`]+)$/i, text) ->
        [_, engine, value] = match
        engine = String.downcase(engine)

        if EngineCatalog.known?(engine) do
          {:ok, %ResumeToken{engine: engine, value: value}}
        else
          :none
        end

      true ->
        :none
    end
  end
end

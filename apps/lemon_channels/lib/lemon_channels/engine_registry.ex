defmodule LemonChannels.EngineRegistry do
  @moduledoc """
  Temporary compatibility parser for resume lines.

  Validation and formatting belong in `LemonCore.EngineCatalog` and
  `LemonCore.ResumeToken`. This module remains only because gateway-provided
  custom engines may expose additional resume syntax through the gateway
  registry at runtime.
  """

  alias LemonCore.{EngineCatalog, ResumeToken}

  @gateway_engine_registry :"Elixir.LemonGateway.EngineRegistry"

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

  defp safe_gateway_extract_resume(text) do
    if (Code.ensure_loaded?(@gateway_engine_registry) and
          Process.whereis(@gateway_engine_registry)) &&
         function_exported?(@gateway_engine_registry, :extract_resume, 1) do
      apply(@gateway_engine_registry, :extract_resume, [text])
    else
      :none
    end
  rescue
    _ -> :none
  end

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

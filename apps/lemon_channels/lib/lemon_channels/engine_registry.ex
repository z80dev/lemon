defmodule LemonChannels.EngineRegistry do
  @moduledoc """
  Resume-line parsing for inbound channel messages.

  Three sources answer, in order of authority:

    1. the engine runtime, asked through `LemonCore.EngineInfoBridge` — its
       engines may accept syntax nothing else knows about;
    2. `LemonCore.ResumeToken`, which reads whatever resume formats the vendor
       packages registered at boot;
    3. the generic `<engine> resume <token>` line, accepted for any engine
       `LemonCore.EngineCatalog` knows.

  Unlike `LemonCore.ResumeToken.extract_resume/1`, this is line-strict: a user
  message is prose, and a resume token is only honoured when the user wrote a
  line that is nothing but the resume command.
  """

  alias LemonCore.{EngineCatalog, EngineInfoBridge, ResumeToken}

  @generic_resume ~r/^([a-z0-9_-]+)\s+resume\s+([^\s`]+)$/i

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
        case parse_line(String.trim(line)) do
          {:ok, _} = ok -> ok
          _ -> nil
        end
      end) || :none
    end
  end

  defp parse_line(line) do
    cond do
      ResumeToken.is_resume_line(line) ->
        case ResumeToken.extract_resume(line) do
          %ResumeToken{} = token -> {:ok, token}
          _ -> :none
        end

      match = Regex.run(@generic_resume, line) ->
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

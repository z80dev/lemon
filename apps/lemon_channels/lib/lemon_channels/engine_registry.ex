defmodule LemonChannels.EngineRegistry do
  @moduledoc """
  Strict native resume-line parsing for inbound channel messages.

  Channel routing only accepts a complete `lemon resume <token>` line. Vendor
  formats and custom engine syntax remain available for delegated task metadata,
  but cannot select a top-level channel engine.
  """

  alias LemonCore.ResumeToken

  @native_engine "lemon"

  @spec extract_resume(String.t()) :: {:ok, ResumeToken.t()} | :none
  def extract_resume(text) when is_binary(text), do: parse_resume_line(text)

  def extract_resume(_), do: :none

  defp parse_resume_line(text) do
    text
    |> String.trim()
    |> String.trim("`")
    |> String.split("\n", trim: true)
    |> Enum.find_value(:none, fn line ->
      line = String.trim(line)

      if ResumeToken.is_resume_line(line, @native_engine) do
        case ResumeToken.extract_resume(line, @native_engine) do
          %ResumeToken{} = token -> {:ok, token}
          _ -> nil
        end
      end
    end)
  end
end

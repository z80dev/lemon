defmodule LemonGateway.EngineDirective do
  @moduledoc false

  @doc """
  Strip a leading engine directive from text.

  Examples:
  - `/codex fix this` -> `{"codex", "fix this"}`
  - `/claude` -> `{"claude", ""}`
  - `hello` -> `{nil, "hello"}`
  """
  @spec strip(String.t() | nil) :: {String.t() | nil, String.t()}
  def strip(text) when is_binary(text) do
    text = String.trim(text)

    case Regex.run(~r{^/(lemon|codex|claude|opencode|pi|echo)\b\s*(.*)$}is, text) do
      [_, engine, rest] -> {String.downcase(engine), String.trim(rest)}
      _ -> {nil, text}
    end
  end

  def strip(_), do: {nil, ""}
end

defmodule LemonGateway.EngineDirective do
  @moduledoc """
  Parses and strips leading engine directives from user input text.

  An engine directive is a slash prefix such as `/claude` or `/codex` that selects
  which engine should handle the request. The directive is stripped and the
  engine name and remaining text are returned separately.
  """

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

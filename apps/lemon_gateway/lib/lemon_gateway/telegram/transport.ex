defmodule LemonGateway.Telegram.Transport do
  @moduledoc false

  use LemonGateway.Transport
  require Logger

  @impl LemonGateway.Transport
  def id, do: "telegram"

  @impl LemonGateway.Transport
  def start_link(_opts) do
    Logger.warning(
      "Legacy LemonGateway Telegram transport is removed; use lemon_channels adapter"
    )

    :ignore
  end

  @doc """
  Strip a leading engine directive from text.

  Examples:
  - `/codex fix this` -> `{"codex", "fix this"}`
  - `/claude` -> `{"claude", ""}`
  - `hello` -> `{nil, "hello"}`
  """
  @spec strip_engine_directive(String.t() | nil) :: {String.t() | nil, String.t()}
  def strip_engine_directive(text) when is_binary(text) do
    text = String.trim(text)

    case Regex.run(~r{^/(lemon|codex|claude|opencode|pi|echo)\b\s*(.*)$}is, text) do
      [_, engine, rest] -> {String.downcase(engine), String.trim(rest)}
      _ -> {nil, text}
    end
  end

  def strip_engine_directive(_), do: {nil, ""}
end

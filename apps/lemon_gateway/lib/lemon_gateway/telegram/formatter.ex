defmodule LemonGateway.Telegram.Formatter do
  @moduledoc """
  Formats markdown for Telegram in a robust way.

  We avoid Telegram's MarkdownV2 escaping (fragile) and instead render markdown into
  plain text with Telegram `entities` (UTF-16 offsets) for formatting.
  """

  alias LemonGateway.Telegram.Markdown

  @doc """
  Prepare markdown text for Telegram.

  Returns `{text, opts}` where `opts` is a map suitable for passing to
  `LemonGateway.Telegram.API.send_message/4` or `edit_message_text/5`.
  """
  @spec prepare_for_telegram(String.t() | nil) :: {String.t(), map() | nil}
  def prepare_for_telegram(text) when is_binary(text) do
    {rendered, entities} = Markdown.render(text)

    opts =
      case entities do
        [] -> nil
        _ -> %{entities: entities}
      end

    {rendered, opts}
  end

  def prepare_for_telegram(nil), do: {"", nil}
end

defmodule LemonChannels.Telegram.Formatter do
  @moduledoc """
  Formats markdown for Telegram in a robust way.

  We avoid Telegram's MarkdownV2 escaping (fragile) and instead render markdown into
  plain text with Telegram `entities` (UTF-16 offsets) for formatting.
  """

  alias LemonChannels.Telegram.Markdown

  @doc """
  Prepare markdown text for Telegram.

  Returns `{text, opts}` where `opts` is a map suitable for passing to
  `LemonChannels.Telegram.API.send_message/4` or `edit_message_text/5`.
  """
  @spec prepare_for_telegram(String.t() | nil) :: {String.t(), map() | nil}
  def prepare_for_telegram(text) when is_binary(text) do
    {rendered0, entities0} = Markdown.render(text)

    # Guard against malformed markdown producing an empty render while the original
    # text is non-empty (e.g., unclosed code fences). In that case, send plain text
    # so Telegram doesn't reject the message as empty.
    {rendered, entities} =
      if markdown_render_empty?(text, rendered0) do
        {text, []}
      else
        {rendered0, entities0}
      end

    opts =
      case entities do
        [] -> nil
        _ -> %{entities: entities}
      end

    {rendered, opts}
  end

  def prepare_for_telegram(nil), do: {"", nil}

  defp markdown_render_empty?(source, rendered)
       when is_binary(source) and is_binary(rendered) do
    String.trim(source) != "" and String.trim(rendered) == ""
  end
end

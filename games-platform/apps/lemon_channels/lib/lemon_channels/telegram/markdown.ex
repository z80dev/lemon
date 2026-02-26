defmodule LemonChannels.Telegram.Markdown do
  @moduledoc """
  Renders CommonMark-ish markdown into Telegram-ready `{text, entities}` tuples.

  Instead of using Telegram MarkdownV2 escaping, this module parses markdown via
  EarmarkParser, emits plain text, and attaches Telegram "entities" with UTF-16
  offsets and lengths. Supported entity types: bold, italic, underline,
  strikethrough, code, pre, and text_link.
  """

  @type entity :: map()

  @doc """
  Render a markdown string into `{plain_text, entities}` for the Telegram Bot API.

  Returns `{"", []}` when given `nil`.
  """
  @spec render(String.t() | nil) :: {String.t(), [entity()]}
  def render(md) when is_binary(md) do
    ast = parse_ast(md)

    acc = %{iodata_rev: [], entities_rev: [], offset: 0, mode: :root}
    acc = render_nodes(ast, acc)

    entities = Enum.reverse(acc.entities_rev)

    text =
      acc.iodata_rev
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> replace_leading_bullets()
      |> trim_trailing_safe(entities)

    {text, entities}
  end

  def render(nil), do: {"", []}

  defp parse_ast(md) when is_binary(md) do
    if Code.ensure_loaded?(EarmarkParser) and function_exported?(EarmarkParser, :as_ast, 1) do
      case apply(EarmarkParser, :as_ast, [md]) do
        {:ok, ast, _messages} -> ast
        {:error, ast, _messages} -> ast
        _ -> [md]
      end
    else
      [md]
    end
  rescue
    _ -> [md]
  end

  defp replace_leading_bullets(text) do
    # Keep entity offsets stable: "•" -> "-" is a 1:1 replacement.
    Regex.replace(~r/^(\\s*)•/m, text, "\\1-")
  end

  defp trim_trailing_safe(text, entities) when is_binary(text) and is_list(entities) do
    max_end =
      Enum.reduce(entities, 0, fn ent, acc ->
        off = ent["offset"]
        len = ent["length"]

        if is_integer(off) and is_integer(len) do
          max(acc, off + len)
        else
          acc
        end
      end)

    trimmed = String.trim_trailing(text)

    if utf16_len(trimmed) >= max_end do
      trimmed
    else
      text
    end
  end

  defp render_nodes(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &render_node/2)
  end

  defp render_nodes(node, acc), do: render_node(node, acc)

  defp render_node(text, acc) when is_binary(text) do
    emit(acc, text)
  end

  defp render_node({tag, attrs, children, _meta}, acc) when is_binary(tag) and is_list(attrs) do
    case tag do
      "p" ->
        acc = render_nodes(children, acc)

        if acc.mode == :list_item do
          acc
        else
          emit(acc, "\n\n")
        end

      "br" ->
        emit(acc, "\n")

      "strong" ->
        with_entity(acc, "bold", fn a -> render_nodes(children, a) end)

      "em" ->
        with_entity(acc, "italic", fn a -> render_nodes(children, a) end)

      "u" ->
        with_entity(acc, "underline", fn a -> render_nodes(children, a) end)

      "del" ->
        with_entity(acc, "strikethrough", fn a -> render_nodes(children, a) end)

      "s" ->
        with_entity(acc, "strikethrough", fn a -> render_nodes(children, a) end)

      "code" ->
        # Inline code; code blocks come through as <pre><code>..</code></pre>.
        with_entity(acc, "code", fn a -> render_nodes(children, a) end)

      "pre" ->
        render_pre(children, acc)

      "a" ->
        url = get_attr(attrs, "href")

        if is_binary(url) and url != "" do
          with_entity(acc, "text_link", fn a -> render_nodes(children, a) end, %{"url" => url})
        else
          render_nodes(children, acc)
        end

      "h1" ->
        render_heading(children, acc)

      "h2" ->
        render_heading(children, acc)

      "h3" ->
        render_heading(children, acc)

      "h4" ->
        render_heading(children, acc)

      "h5" ->
        render_heading(children, acc)

      "h6" ->
        render_heading(children, acc)

      "ul" ->
        render_ul(children, acc)

      "ol" ->
        render_ol(attrs, children, acc)

      "li" ->
        # List containers handle prefixes and newlines.
        render_nodes(children, %{acc | mode: :list_item})

      "blockquote" ->
        # Render as plain text with a "> " prefix. We intentionally drop nested entities
        # to avoid offset adjustments for per-line prefixes.
        quote = render_plain(children)

        quote =
          quote
          |> String.split("\n", trim: false)
          |> Enum.map_join("\n", fn line -> if line == "", do: ">", else: "> " <> line end)

        acc = emit(acc, quote)
        emit(acc, "\n\n")

      _ ->
        render_nodes(children, acc)
    end
  end

  defp render_node({_other, _attrs, children, _meta}, acc) when is_list(children) do
    render_nodes(children, acc)
  end

  defp render_node(_other, acc), do: acc

  defp render_heading(children, acc) do
    acc = with_entity(acc, "bold", fn a -> render_nodes(children, a) end)
    emit(acc, "\n\n")
  end

  defp render_ul(items, acc) do
    acc =
      Enum.reduce(items, acc, fn
        {"li", _attrs, li_children, _meta}, a ->
          a = emit(a, "- ")
          a = render_nodes(li_children, %{a | mode: :list_item})
          emit(a, "\n")

        other, a ->
          render_node(other, a)
      end)

    if acc.mode == :list_item do
      acc
    else
      emit(acc, "\n")
    end
  end

  defp render_ol(attrs, items, acc) do
    start =
      case get_attr(attrs, "start") do
        nil -> 1
        raw -> parse_int(raw, 1)
      end

    {acc, _n} =
      Enum.reduce(items, {acc, start}, fn
        {"li", _attrs, li_children, _meta}, {a, n} ->
          a = emit(a, "#{n}. ")
          a = render_nodes(li_children, %{a | mode: :list_item})
          {emit(a, "\n"), n + 1}

        other, {a, n} ->
          {render_node(other, a), n}
      end)

    if acc.mode == :list_item do
      acc
    else
      emit(acc, "\n")
    end
  end

  defp render_pre(children, acc) do
    {code_text, language} = extract_pre_code(children)

    if code_text == "" do
      acc
    else
      ent_extra =
        if is_binary(language) and language != "", do: %{"language" => language}, else: %{}

      acc =
        with_entity(
          acc,
          "pre",
          fn a ->
            # Preserve code verbatim. Telegram expects newlines to be part of the text.
            emit(a, code_text)
          end,
          ent_extra
        )

      if acc.mode == :list_item do
        acc
      else
        emit(acc, "\n\n")
      end
    end
  end

  defp extract_pre_code(children) do
    # Earmark typically emits: {"pre", [], [{"code", [{"class","language-elixir"}], ["..."], _}], _}
    case children do
      [{"code", attrs, code_children, _meta}] ->
        code_text = IO.iodata_to_binary(code_children)
        lang = language_from_class(get_attr(attrs, "class"))
        {code_text, lang}

      [text] when is_binary(text) ->
        {text, nil}

      _ ->
        {IO.iodata_to_binary(flatten_text(children)), nil}
    end
  end

  defp language_from_class(nil), do: nil

  defp language_from_class(class) when is_binary(class) do
    case Regex.run(~r/(?:^|\\s)language-([\\w#+.-]+)/, class) do
      [_, lang] ->
        lang

      _ ->
        # EarmarkParser uses `class="elixir"` for fenced code blocks.
        if String.contains?(class, " ") do
          nil
        else
          String.trim(class)
        end
    end
  end

  defp render_plain(nodes) do
    acc = %{iodata_rev: [], offset: 0, mode: :root}
    acc = render_nodes_plain(nodes, acc)

    acc.iodata_rev
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp render_nodes_plain(nodes, acc) when is_list(nodes) do
    Enum.reduce(nodes, acc, &render_node_plain/2)
  end

  defp render_nodes_plain(node, acc), do: render_node_plain(node, acc)

  defp render_node_plain(text, acc) when is_binary(text), do: emit_plain(acc, text)

  defp render_node_plain({tag, _attrs, children, _meta}, acc) when is_binary(tag) do
    case tag do
      "br" -> emit_plain(acc, "\n")
      "p" -> render_nodes_plain(children, acc) |> emit_plain("\n")
      "li" -> render_nodes_plain(children, acc)
      _ -> render_nodes_plain(children, acc)
    end
  end

  defp render_node_plain(_other, acc), do: acc

  defp flatten_text(nodes) when is_list(nodes) do
    Enum.map(nodes, fn
      s when is_binary(s) -> s
      {_tag, _attrs, children, _meta} -> flatten_text(children)
      _ -> ""
    end)
  end

  defp with_entity(acc, type, fun, extra \\ %{}) when is_function(fun, 1) do
    start = acc.offset
    acc = fun.(acc)
    finish = acc.offset

    if finish > start do
      ent =
        %{
          "type" => type,
          "offset" => start,
          "length" => finish - start
        }
        |> Map.merge(extra)

      %{acc | entities_rev: [ent | acc.entities_rev]}
    else
      acc
    end
  end

  defp emit(acc, text) when is_binary(text) do
    %{acc | iodata_rev: [text | acc.iodata_rev], offset: acc.offset + utf16_len(text)}
  end

  defp emit_plain(acc, text) when is_binary(text) do
    %{acc | iodata_rev: [text | acc.iodata_rev], offset: acc.offset + utf16_len(text)}
  end

  defp utf16_len(text) when is_binary(text) do
    bin = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    div(byte_size(bin), 2)
  end

  defp get_attr(attrs, key) when is_list(attrs) and is_binary(key) do
    case Enum.find(attrs, fn
           {^key, _} -> true
           _ -> false
         end) do
      {^key, val} -> val
      _ -> nil
    end
  end

  defp parse_int(val, default) when is_integer(default) do
    case Integer.parse(to_string(val)) do
      {i, _} -> i
      :error -> default
    end
  end
end

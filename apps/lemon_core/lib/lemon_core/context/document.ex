defmodule LemonCore.Context.Document do
  @moduledoc """
  Bounded, format-sniffed text extraction for context references.

  The extractor never trusts a filename extension. ZIP containers are
  classified from their entries, validated before any member is inflated, and
  extracted in memory only after traversal, entry-count, expanded-size, and
  compression-ratio checks pass.
  """

  @default_max_input_bytes 8_000_000
  @default_max_output_bytes 120_000
  @default_max_pages 80
  @default_max_items 500
  @default_max_depth 8
  @default_max_archive_bytes 24_000_000
  @default_max_archive_ratio 100

  @type result :: %{
          format: atom(),
          text: String.t(),
          input_bytes: non_neg_integer(),
          output_bytes: non_neg_integer(),
          selected_items: non_neg_integer(),
          omitted: [map()]
        }

  @doc "Extract text from a binary using content signatures, not its name."
  @spec extract_binary(binary(), keyword()) :: {:ok, result()} | {:error, term()}
  def extract_binary(binary, opts \\ []) when is_binary(binary) do
    max_input = limit(opts, :max_input_bytes, @default_max_input_bytes)

    if byte_size(binary) > max_input do
      {:error, {:input_too_large, byte_size(binary), max_input}}
    else
      with {:ok, format} <- sniff(binary),
           {:ok, text, selected_items, omitted} <- extract(format, binary, opts) do
        {selected, truncated?} =
          take_bytes(
            normalize_text(text),
            limit(opts, :max_output_bytes, @default_max_output_bytes)
          )

        omitted =
          if truncated? do
            omitted ++
              [%{reason: "output_budget", omitted_bytes: byte_size(text) - byte_size(selected)}]
          else
            omitted
          end

        {:ok,
         %{
           format: format,
           text: selected,
           input_bytes: byte_size(binary),
           output_bytes: byte_size(selected),
           selected_items: selected_items,
           omitted: omitted
         }}
      end
    end
  end

  @doc "Classify a supported document from its bytes."
  @spec sniff(binary()) :: {:ok, atom()} | {:error, :unsupported_format}
  def sniff(<<"%PDF-", _::binary>>), do: {:ok, :pdf}

  def sniff(<<"PK", _::binary>> = binary) do
    with_temp_zip(binary, fn path ->
      with {:ok, entries} <- zip_entries(path),
           {:ok, format} <- classify_zip(entries) do
        {:ok, format}
      end
    end)
  end

  def sniff(binary) do
    case Jason.decode(binary) do
      {:ok, %{"cells" => cells, "nbformat" => version}}
      when is_list(cells) and is_integer(version) ->
        {:ok, :ipynb}

      _ ->
        if String.valid?(binary), do: {:ok, :text}, else: {:error, :unsupported_format}
    end
  end

  defp extract(:text, binary, _opts), do: {:ok, binary, line_count(binary), []}
  defp extract(:ipynb, binary, opts), do: extract_notebook(binary, opts)
  defp extract(:pdf, binary, opts), do: extract_pdf(binary, opts)

  defp extract(format, binary, opts) when format in [:docx, :xlsx, :pptx] do
    with_temp_zip(binary, fn path ->
      with {:ok, entries} <- zip_entries(path),
           :ok <- validate_archive(entries, opts),
           {:ok, members} <- extract_archive(path, entries, format, opts) do
        extract_office(format, members, opts)
      end
    end)
  end

  defp extract_notebook(binary, opts) do
    max_items = limit(opts, :max_items, @default_max_items)
    max_depth = limit(opts, :max_depth, @default_max_depth)

    with {:ok, notebook} <- Jason.decode(binary),
         :ok <- validate_json_depth(notebook, max_depth) do
      cells = Map.get(notebook, "cells", [])
      selected = Enum.take(cells, max_items)

      text =
        selected
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {cell, index} ->
          kind = Map.get(cell, "cell_type", "unknown")
          source = cell |> Map.get("source", []) |> source_text()
          "## Cell #{index} (#{kind})\n#{source}"
        end)

      omitted =
        if length(cells) > length(selected),
          do: [%{reason: "item_limit", omitted_items: length(cells) - length(selected)}],
          else: []

      {:ok, text, length(selected), omitted}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_notebook}
      {:error, _} = error -> error
    end
  end

  defp extract_pdf(binary, opts) do
    pages = max(length(Regex.scan(~r{/Type\s*/Page\b}, binary)), 1)
    max_pages = limit(opts, :max_pages, @default_max_pages)

    if pages > max_pages do
      {:error, {:page_limit, pages, max_pages}}
    else
      strings =
        Regex.scan(~r/\(((?:\\.|[^\\)])*)\)\s*(?:Tj|'|")/s, binary, capture: :all_but_first)
        |> Enum.map(fn [value] -> decode_pdf_literal(value) end)

      array_strings =
        Regex.scan(~r/\[(.*?)\]\s*TJ/s, binary, capture: :all_but_first)
        |> Enum.flat_map(fn [array] ->
          Regex.scan(~r/\(((?:\\.|[^\\)])*)\)/s, array, capture: :all_but_first)
          |> Enum.map(fn [value] -> decode_pdf_literal(value) end)
        end)

      text = Enum.join(strings ++ array_strings, "\n")

      if String.trim(text) == "" do
        {:error, :pdf_text_unavailable}
      else
        {:ok, text, pages, []}
      end
    end
  end

  defp extract_office(:docx, members, _opts) do
    case Map.fetch(members, "word/document.xml") do
      {:ok, xml} -> {:ok, xml_text(xml, paragraph_tags: ["w:p"]), 1, []}
      :error -> {:error, :invalid_docx}
    end
  end

  defp extract_office(:pptx, members, opts) do
    slides =
      members
      |> Enum.filter(fn {name, _} -> Regex.match?(~r{^ppt/slides/slide\d+\.xml$}, name) end)
      |> Enum.sort_by(fn {name, _} -> numeric_suffix(name) end)

    select_xml_items(slides, limit(opts, :max_pages, @default_max_pages), "slide_limit", fn {name,
                                                                                             xml} ->
      "## #{Path.basename(name, ".xml")}\n" <> xml_text(xml, paragraph_tags: ["a:p"])
    end)
  end

  defp extract_office(:xlsx, members, opts) do
    shared =
      members
      |> Map.get("xl/sharedStrings.xml", "")
      |> xml_nodes("si")
      |> Enum.map(&xml_text/1)

    sheets =
      members
      |> Enum.filter(fn {name, _} -> Regex.match?(~r{^xl/worksheets/sheet\d+\.xml$}, name) end)
      |> Enum.sort_by(fn {name, _} -> numeric_suffix(name) end)

    select_xml_items(sheets, limit(opts, :max_items, @default_max_items), "item_limit", fn {name,
                                                                                            xml} ->
      rows =
        xml_nodes(xml, "row")
        |> Enum.map(fn row ->
          xml_elements(row, "c")
          |> Enum.map(fn cell -> xlsx_cell_text(cell, shared) end)
          |> Enum.join("\t")
        end)

      "## #{Path.basename(name, ".xml")}\n" <> Enum.join(rows, "\n")
    end)
  end

  defp select_xml_items(items, max, reason, render) do
    selected = Enum.take(items, max)
    text = Enum.map_join(selected, "\n\n", render)

    omitted =
      if length(items) > length(selected),
        do: [%{reason: reason, omitted_items: length(items) - length(selected)}],
        else: []

    {:ok, text, length(selected), omitted}
  end

  defp xlsx_cell_text(cell, shared) do
    value = xml_first_text(cell, "v")

    cond do
      Regex.match?(~r{<c\b[^>]*\bt=["']s["']}, cell) ->
        case Integer.parse(value) do
          {index, ""} -> Enum.at(shared, index, "")
          _ -> ""
        end

      Regex.match?(~r{<c\b[^>]*\bt=["']inlineStr["']}, cell) ->
        xml_text(cell)

      true ->
        value
    end
  end

  defp classify_zip(entries) do
    names = MapSet.new(Enum.map(entries, & &1.name))

    cond do
      MapSet.member?(names, "word/document.xml") -> {:ok, :docx}
      Enum.any?(names, &String.starts_with?(&1, "xl/worksheets/")) -> {:ok, :xlsx}
      Enum.any?(names, &String.starts_with?(&1, "ppt/slides/")) -> {:ok, :pptx}
      true -> {:error, :unsupported_format}
    end
  end

  defp zip_entries(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, raw} ->
        entries =
          Enum.flat_map(raw, fn
            {:zip_file, name, info, _comment, _offset, compressed_size} ->
              [
                %{
                  name: List.to_string(name),
                  size: elem(info, 1),
                  type: elem(info, 2),
                  compressed_size: compressed_size
                }
              ]

            _ ->
              []
          end)

        {:ok, entries}

      {:error, reason} ->
        {:error, {:invalid_archive, reason}}
    end
  end

  defp validate_archive(entries, opts) do
    max_items = limit(opts, :max_items, @default_max_items)
    max_bytes = limit(opts, :max_archive_bytes, @default_max_archive_bytes)
    max_ratio = limit(opts, :max_archive_ratio, @default_max_archive_ratio)
    total = Enum.sum(Enum.map(entries, & &1.size))

    cond do
      length(entries) > max_items ->
        {:error, {:archive_item_limit, length(entries), max_items}}

      total > max_bytes ->
        {:error, {:archive_size_limit, total, max_bytes}}

      Enum.any?(entries, &unsafe_archive_name?(&1.name)) ->
        {:error, :archive_path_traversal}

      Enum.any?(entries, &(&1.type not in [:regular, :directory])) ->
        {:error, :archive_special_file}

      Enum.any?(entries, &(archive_ratio(&1) > max_ratio)) ->
        {:error, :archive_ratio_limit}

      true ->
        :ok
    end
  end

  defp extract_archive(path, entries, format, opts) do
    wanted = wanted_entries(entries, format, opts)
    names = Enum.map(wanted, &String.to_charlist(&1.name))

    case :zip.extract(String.to_charlist(path), [:memory, {:file_list, names}]) do
      {:ok, files} ->
        {:ok,
         Map.new(files, fn {name, body} -> {List.to_string(name), IO.iodata_to_binary(body)} end)}

      {:error, reason} ->
        {:error, {:archive_extract_failed, reason}}
    end
  end

  defp wanted_entries(entries, :docx, _opts),
    do: Enum.filter(entries, &(&1.name == "word/document.xml"))

  defp wanted_entries(entries, :xlsx, _opts) do
    Enum.filter(entries, fn entry ->
      entry.name == "xl/sharedStrings.xml" or
        Regex.match?(~r{^xl/worksheets/sheet\d+\.xml$}, entry.name)
    end)
  end

  defp wanted_entries(entries, :pptx, _opts),
    do: Enum.filter(entries, &Regex.match?(~r{^ppt/slides/slide\d+\.xml$}, &1.name))

  defp unsafe_archive_name?(name) do
    Path.type(name) == :absolute or
      name
      |> String.replace("\\", "/")
      |> String.split("/", trim: true)
      |> Enum.any?(&(&1 == ".."))
  end

  defp archive_ratio(%{size: size, compressed_size: compressed}) when compressed > 0,
    do: size / compressed

  defp archive_ratio(%{size: 0}), do: 0
  defp archive_ratio(_), do: :infinity

  defp with_temp_zip(binary, fun) do
    path =
      Path.join(
        System.tmp_dir!(),
        "lemon-context-#{System.unique_integer([:positive, :monotonic])}.zip"
      )

    try do
      with :ok <- File.write(path, binary, [:binary, :exclusive]) do
        fun.(path)
      end
    after
      File.rm(path)
    end
  end

  defp validate_json_depth(value, max), do: do_validate_json_depth(value, 0, max)

  defp do_validate_json_depth(_value, depth, max) when depth > max,
    do: {:error, {:depth_limit, max}}

  defp do_validate_json_depth(value, depth, max) when is_map(value) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      case do_validate_json_depth(key, depth + 1, max) do
        :ok ->
          case do_validate_json_depth(item, depth + 1, max) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp do_validate_json_depth(value, depth, max) when is_list(value) do
    Enum.reduce_while(value, :ok, fn item, :ok ->
      case do_validate_json_depth(item, depth + 1, max) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp do_validate_json_depth(_value, _depth, _max), do: :ok

  defp source_text(value) when is_list(value), do: Enum.map_join(value, "", &to_string/1)
  defp source_text(value) when is_binary(value), do: value
  defp source_text(_), do: ""

  defp xml_nodes(xml, tag) do
    Regex.scan(
      Regex.compile!("<#{Regex.escape(tag)}\\b[^>]*>(.*?)</#{Regex.escape(tag)}>", "s"),
      xml,
      capture: :all_but_first
    )
    |> Enum.map(&hd/1)
  end

  defp xml_elements(xml, tag) do
    Regex.scan(
      Regex.compile!("(<#{Regex.escape(tag)}\\b[^>]*>.*?</#{Regex.escape(tag)}>)", "s"),
      xml,
      capture: :all_but_first
    )
    |> Enum.map(&hd/1)
  end

  defp xml_first_text(xml, tag), do: xml |> xml_nodes(tag) |> List.first("") |> xml_text()

  defp xml_text(xml, opts \\ []) do
    paragraph_tags = Keyword.get(opts, :paragraph_tags, [])

    xml =
      Enum.reduce(paragraph_tags, xml, fn tag, acc ->
        Regex.replace(Regex.compile!("</#{Regex.escape(tag)}>", "i"), acc, "\n")
      end)

    Regex.replace(~r/<[^>]+>/s, xml, "")
    |> decode_entities()
    |> normalize_text()
  end

  defp decode_entities(text) do
    decoded =
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&amp;", "&")

    Regex.replace(~r/&#(\d+);/, decoded, fn _, digits ->
      case Integer.parse(digits) do
        {codepoint, ""} when codepoint <= 0x10FFFF -> <<codepoint::utf8>>
        _ -> ""
      end
    end)
  end

  defp decode_pdf_literal(value) do
    value
    |> String.replace(~r/\\([\\()])/, "\\1")
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\n")
    |> String.replace("\\t", "\t")
  end

  defp numeric_suffix(name) do
    case Regex.run(~r/(\d+)(?:\.xml)?$/, name, capture: :all_but_first) do
      [digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  defp normalize_text(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/[\t ]+\n/, "\n")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp take_bytes(binary, max) when byte_size(binary) <= max, do: {binary, false}

  defp take_bytes(binary, max) do
    candidate = binary_part(binary, 0, max)
    {trim_invalid_utf8(candidate), true}
  end

  defp trim_invalid_utf8(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_invalid_utf8(binary_part(binary, 0, byte_size(binary) - 1))
  end

  defp line_count(""), do: 0
  defp line_count(binary), do: length(:binary.matches(binary, "\n")) + 1

  defp limit(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end

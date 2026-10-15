defmodule CodingAgent.Tools.ReadFormatText do
  @moduledoc false

  alias CodingAgent.Tools.ReadText
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def result(content, source, params, signal, opts, details \\ %{}) do
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit")
    max_lines = Keyword.get(opts, :max_lines, 2000)
    max_bytes = Keyword.get(opts, :max_bytes, 50 * 1024)
    raw? = Keyword.get(opts, :raw, false)

    with :ok <- check_abort(signal),
         :ok <- validate_text(content) do
      all_lines = String.split(content, "\n")

      all_lines =
        if String.ends_with?(content, "\n"), do: Enum.drop(all_lines, -1), else: all_lines

      total = length(all_lines)

      if offset > total do
        {:error, "offset=#{offset} is beyond the end of the rendered source (#{total} lines)."}
      else
        selected = Enum.drop(all_lines, offset - 1)
        selected = if limit, do: Enum.take(selected, limit), else: selected
        # Reserve original-number width and a source-bearing continuation footer.
        number_margin =
          if raw?,
            do: 0,
            else: byte_size(Integer.to_string(total)) * min(length(selected), max_lines)

        footer_margin = min(320 + byte_size(source), div(max_bytes, 2))
        budget = max(max_bytes - number_margin - footer_margin, 1)

        with {:ok, window} <-
               ReadText.from_content(Enum.join(selected, "\n") <> "\n", max_lines, budget),
             :ok <- check_abort(signal) do
          shown = length(window.lines)
          next = offset + shown
          remaining = next <= total
          reason = window.truncation || if(remaining, do: "limit", else: nil)

          truncation =
            if reason do
              message =
                if reason == "long_line" do
                  "[Line #{offset} exceeds the read budget; only a prefix is shown. Full source: #{source}. Use external byte-range inspection for this line; offset=#{next} continues later lines.]"
                else
                  "[Showing lines #{offset}-#{next - 1} of #{total}. Read #{source} with offset=#{next} to continue.]"
                end

              %{truncated: true, reason: reason, next_offset: next, message: message}
            end

          text =
            if raw? do
              Enum.join(window.lines, "\n")
            else
              window.lines
              |> Enum.with_index(offset)
              |> Enum.map_join("\n", fn {line, index} -> "#{index}: #{line}" end)
              |> append_footer(truncation, max_bytes)
            end

          if byte_size(text) > max_bytes do
            {:error,
             "The #{max_bytes}-byte read budget cannot fit a numbered line. Increase :max_bytes."}
          else
            {:ok,
             %AgentToolResult{
               content: [%TextContent{text: text}],
               details:
                 Map.merge(details, %{
                   path: source,
                   source_path: source,
                   full_source: source,
                   total_lines: total,
                   start_line: offset,
                   lines_shown: shown,
                   raw: raw?,
                   truncation: truncation,
                   next_offset: if(remaining, do: next)
                 })
             }}
          end
        end
      end
    end
  end

  defp validate_text(content) do
    cond do
      :binary.match(content, <<0>>) != :nomatch ->
        {:error, "Source is binary; use an external backend for binary inspection."}

      not String.valid?(content) ->
        {:error, "Source contains invalid UTF-8; use an external backend for conversion."}

      true ->
        :ok
    end
  end

  defp append_footer(text, nil, _max_bytes), do: text

  defp append_footer(text, truncation, max_bytes) do
    full = text <> "\n" <> truncation.message
    short = text <> "\n[Truncated; continuation and full source are in result details.]"

    cond do
      byte_size(full) <= max_bytes -> full
      byte_size(short) <= max_bytes -> short
      true -> text
    end
  end
end

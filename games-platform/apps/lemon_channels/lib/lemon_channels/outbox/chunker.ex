defmodule LemonChannels.Outbox.Chunker do
  @moduledoc """
  Chunker for splitting long messages into channel-sized pieces.

  Different channels have different message size limits. The chunker
  splits messages intelligently at word/sentence boundaries.
  """

  @default_chunk_size 4096

  @doc """
  Split text into chunks that fit within the size limit.

  ## Options

  - `:chunk_size` - Maximum characters per chunk (default: 4096)
  - `:preserve_words` - Try to break at word boundaries (default: true)
  - `:preserve_sentences` - Try to break at sentence boundaries (default: true)
  """
  @spec chunk(text :: binary(), opts :: keyword()) :: [binary()]
  def chunk(text, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    preserve_words = Keyword.get(opts, :preserve_words, true)
    preserve_sentences = Keyword.get(opts, :preserve_sentences, true)

    if String.length(text) <= chunk_size do
      [text]
    else
      do_chunk(text, chunk_size, preserve_words, preserve_sentences, [])
    end
  end

  @doc """
  Get the recommended chunk size for a channel.
  """
  @spec chunk_size_for(channel_id :: binary()) :: non_neg_integer()
  def chunk_size_for(channel_id) do
    case LemonChannels.Registry.get_meta(channel_id) do
      nil ->
        @default_chunk_size

      %{capabilities: %{chunk_limit: limit}} ->
        limit

      _ ->
        @default_chunk_size
    end
  end

  defp do_chunk("", _chunk_size, _preserve_words, _preserve_sentences, acc) do
    Enum.reverse(acc)
  end

  defp do_chunk(text, chunk_size, preserve_words, preserve_sentences, acc) do
    if String.length(text) <= chunk_size do
      Enum.reverse([text | acc])
    else
      # Find best break point
      break_point = find_break_point(text, chunk_size, preserve_words, preserve_sentences)

      {chunk, rest} = String.split_at(text, break_point)
      rest = String.trim_leading(rest)

      do_chunk(rest, chunk_size, preserve_words, preserve_sentences, [chunk | acc])
    end
  end

  defp find_break_point(text, max_pos, preserve_words, preserve_sentences) do
    candidate = String.slice(text, 0, max_pos)

    cond do
      # Try sentence boundary first
      preserve_sentences ->
        case find_sentence_break(candidate) do
          nil ->
            if preserve_words do
              find_word_break(candidate) || max_pos
            else
              max_pos
            end

          pos ->
            pos
        end

      # Try word boundary
      preserve_words ->
        find_word_break(candidate) || max_pos

      # Hard break
      true ->
        max_pos
    end
  end

  defp find_sentence_break(text) do
    # Look for sentence endings from the end
    text
    |> String.reverse()
    |> then(fn reversed ->
      case Regex.run(~r/[\.\!\?]\s/, reversed) do
        nil -> nil
        _ -> String.length(text) - find_last_sentence_end(text)
      end
    end)
  end

  defp find_last_sentence_end(text) do
    indices =
      Regex.scan(~r/[\.\!\?]\s/, text, return: :index)
      |> Enum.map(fn [{pos, len}] -> pos + len end)

    case indices do
      [] -> nil
      _ -> List.last(indices)
    end
  end

  defp find_word_break(text) do
    # Find last whitespace
    case Regex.run(~r/\s+/, text |> String.reverse(), return: :index) do
      nil ->
        nil

      [{pos, _len}] ->
        String.length(text) - pos
    end
  end
end

defmodule LemonChannels.Outbox.Chunker do
  @moduledoc """
  Chunker for splitting long messages into channel-sized pieces.

  Different channels have different message size limits. The chunker
  splits messages intelligently at sentence/word boundaries.

  Sizes are counted in graphemes. Every chunk is non-empty and at most
  `:chunk_size` graphemes long, and every split consumes at least one
  grapheme, so chunking always terminates. Whitespace that would start a
  continuation chunk is dropped; everything else is preserved in order.
  """

  @default_chunk_size 4096
  @sentence_ends [".", "!", "?"]

  @doc """
  Split text into chunks that fit within the size limit.

  ## Options

  - `:chunk_size` - Maximum graphemes per chunk, a positive integer (default: 4096)
  - `:preserve_words` - Try to break at word boundaries (default: true)
  - `:preserve_sentences` - Try to break at sentence boundaries (default: true)
  """
  @spec chunk(text :: binary(), opts :: keyword()) :: [binary()]
  def chunk(text, opts \\ []) when is_binary(text) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    preserve_words = Keyword.get(opts, :preserve_words, true)
    preserve_sentences = Keyword.get(opts, :preserve_sentences, true)

    unless is_integer(chunk_size) and chunk_size > 0 do
      raise ArgumentError, "chunk_size must be a positive integer, got: #{inspect(chunk_size)}"
    end

    if String.length(text) <= chunk_size do
      [text]
    else
      text
      |> String.graphemes()
      |> do_chunk(chunk_size, preserve_words, preserve_sentences, [])
    end
  end

  @doc """
  Get the recommended chunk size for a channel.
  """
  @spec chunk_size_for(channel_id :: binary()) :: pos_integer()
  def chunk_size_for(channel_id) do
    case LemonChannels.Registry.get_meta(channel_id) do
      %{capabilities: %{chunk_limit: limit}} when is_integer(limit) and limit > 0 -> limit
      _ -> @default_chunk_size
    end
  end

  defp do_chunk(graphemes, chunk_size, preserve_words, preserve_sentences, acc) do
    case Enum.split(graphemes, chunk_size) do
      {last, []} ->
        Enum.reverse([IO.iodata_to_binary(last) | acc])

      {candidate, _overflow} ->
        # Always in 1..chunk_size, so every iteration makes progress.
        break_point = find_break_point(candidate, chunk_size, preserve_words, preserve_sentences)
        {chunk, rest} = Enum.split(graphemes, break_point)
        acc = [IO.iodata_to_binary(chunk) | acc]

        case Enum.drop_while(rest, &whitespace?/1) do
          [] -> Enum.reverse(acc)
          rest -> do_chunk(rest, chunk_size, preserve_words, preserve_sentences, acc)
        end
    end
  end

  defp find_break_point(candidate, chunk_size, preserve_words, preserve_sentences) do
    (preserve_sentences && sentence_break(candidate)) ||
      (preserve_words && word_break(candidate)) ||
      chunk_size
  end

  # Grapheme index just past the last "<sentence end><whitespace>" pair in the
  # candidate; the whitespace stays on the chunk so joins remain lossless.
  defp sentence_break(candidate) do
    candidate
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {[mark, space], index}, last ->
      if mark in @sentence_ends and whitespace?(space), do: index + 2, else: last
    end)
  end

  # Grapheme index just past the last whitespace grapheme in the candidate.
  defp word_break(candidate) do
    candidate
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {grapheme, index}, last ->
      if whitespace?(grapheme), do: index + 1, else: last
    end)
  end

  defp whitespace?(grapheme), do: String.trim(grapheme) == ""
end

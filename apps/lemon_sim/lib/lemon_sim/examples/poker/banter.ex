defmodule LemonSim.Examples.Poker.Banter do
  @moduledoc """
  Leak filter for public table talk.

  Banter is meant to be fun for spectators without turning into an
  information channel: players may needle, celebrate, and bluff-talk, but
  they may not name specific cards or describe their actual holding. The
  filter is deterministic and errs on the side of blocking — a blocked
  message just prompts the player to rephrase, it never ends the turn.

  Board cards are public, so referencing them is allowed.
  """

  @max_length 240

  @rank_words %{
    "ace" => "A",
    "king" => "K",
    "queen" => "Q",
    "jack" => "J",
    "ten" => "T",
    "nine" => "9",
    "eight" => "8",
    "seven" => "7",
    "six" => "6",
    "five" => "5",
    "four" => "4",
    "three" => "3",
    "trey" => "3",
    "two" => "2",
    "deuce" => "2"
  }

  @suit_words %{
    "spades" => "s",
    "spade" => "s",
    "hearts" => "h",
    "heart" => "h",
    "diamonds" => "d",
    "diamond" => "d",
    "clubs" => "c",
    "club" => "c"
  }

  # Short notation like "Ah", "10s", case-insensitive so "KH" is caught too.
  @short_card_re ~r/\b((?:10|[AKQJT2-9])[SHDC])\b/i

  # Verbose notation like "ace of spades".
  @verbose_card_re ~r/\b(ace|king|queen|jack|ten|nine|eight|seven|six|five|four|trey|three|deuce|two)s?\s+of\s+(spades?|hearts?|diamonds?|clubs?)\b/i

  # "pocket <anything card-like>" always describes hole cards.
  @pocket_re ~r/\bpocket\s+(aces|kings|queens|jacks|tens|nines|eights|sevens|sixes|fives|fours|threes|twos|deuces|rockets|cowboys|ladies|pairs?)\b/i

  # First-person holding claims followed closely by a concrete rank/suit.
  @claim_re ~r/\b(i\s+(?:have|hold|got|had|was\s+dealt)|i'?ve\s+got|i'?m\s+holding|holding|my\s+(?:hole\s+)?cards?|my\s+hand\s+is|dealt\s+me)\b[\s\S]{0,40}?\b(aces?|kings?|queens?|jacks?|tens?|nines?|eights?|sevens?|sixes?|fives?|fours?|threes?|twos?|deuces?|pairs?|suited|off-?suit|spades?|hearts?|diamonds?|clubs?|connectors?)\b/i

  @doc """
  Validates a banter message against the public board.

  Returns `{:ok, message}` with the trimmed (and length-capped) message, or
  `{:error, reason_message}` with a human-readable explanation the player
  can act on. `board` is the list of public card short strings ("Qh").
  """
  @spec sanitize(term(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def sanitize(message, board) when is_list(board) do
    message =
      message
      |> to_string()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.slice(0, @max_length)

    board = MapSet.new(board, &canonical_short/1)

    cond do
      message == "" ->
        {:error, "say something or skip the table talk"}

      leaked = off_board_card_mention(message, board) ->
        {:error,
         "table talk blocked: it references the card #{leaked}, which is not on the board. " <>
           "Never mention specific cards that are not public."}

      Regex.match?(@pocket_re, message) or Regex.match?(@claim_re, message) ->
        {:error,
         "table talk blocked: it describes your holding. " <>
           "Bluff-talk and needling are fine, but never state what you were dealt."}

      true ->
        {:ok, message}
    end
  end

  defp off_board_card_mention(message, board) do
    (short_mentions(message) ++ verbose_mentions(message))
    |> Enum.find(fn short -> not MapSet.member?(board, short) end)
  end

  defp short_mentions(message) do
    @short_card_re
    |> Regex.scan(message, return: :index)
    |> Enum.map(fn [_full, {start, len}] -> {binary_part(message, start, len), start} end)
    |> Enum.reject(fn {token, start} -> english_word?(token, message, start) end)
    |> Enum.map(fn {token, _start} -> canonical_short(token) end)
  end

  defp verbose_mentions(message) do
    @verbose_card_re
    |> Regex.scan(message)
    |> Enum.map(fn [_full, rank, suit] ->
      rank_char = Map.fetch!(@rank_words, String.downcase(rank))
      suit_char = Map.fetch!(@suit_words, String.downcase(suit))
      rank_char <> suit_char
    end)
  end

  # "as" and "ah" are common English words; only treat them as cards when
  # they are unambiguous — mixed/odd case, or capitalized mid-sentence.
  defp english_word?(token, message, start) do
    case token do
      t when t in ["as", "ah"] -> true
      t when t in ["As", "Ah"] -> sentence_start?(message, start)
      _other -> false
    end
  end

  defp sentence_start?(_message, 0), do: true

  defp sentence_start?(message, start) do
    message
    |> binary_part(0, start)
    |> String.trim_trailing()
    |> String.last()
    |> Kernel.in([nil, ".", "!", "?", "\"", "'", ":", ";", "-", "—"])
  end

  defp canonical_short(short) do
    short = to_string(short)

    {rank, suit} =
      case String.split_at(short, byte_size(short) - 1) do
        {"10", suit} -> {"T", suit}
        {rank, suit} -> {String.upcase(rank), suit}
      end

    rank <> String.downcase(suit)
  end
end

defmodule LemonPoker.TableTalkPolicy do
  @moduledoc false

  # Short-card forms such as "Ah", "A h", "10d", "Q ♠".
  @explicit_card ~r/\b(?:10|[2-9]|[jqka])\s*(?:[cdhs]|[♣♠♥♦])\b/iu

  @rank_word ~r/\b(?:ace|king|queen|jack|ten|nine|eight|seven|six|five|four|three|two|10|[2-9])\b/iu
  @suit_word ~r/\b(?:clubs?|diamonds?|hearts?|spades?)\b/iu

  @hole_context ~r/\b(?:hole\s*cards?|my\s*cards?|my\s*hand|dealt|i\s*(?:have|had|got|hold(?:ing)?)|i\s*(?:fold(?:ed)?|muck(?:ed)?)|pocket)\b/iu

  @pocket_pair ~r/\bpocket\s+(?:aces?|kings?|queens?|jacks?|tens?|nines?|eights?|sevens?|sixes?|fives?|fours?|threes?|twos?)\b/iu

  @two_rank_combo ~r/\b(?:ace|king|queen|jack|ten|nine|eight|seven|six|five|four|three|two|10|[2-9])\s*(?:-|\/|,|\s)\s*(?:ace|king|queen|jack|ten|nine|eight|seven|six|five|four|three|two|10|[2-9])\b/iu
  @two_rank_shorthand ~r/\b(?:[akqjt2-9]{2})(?:[so])?\b/iu
  @two_rank_shorthand_spaced ~r/\b(?:[akqjt2-9])\s*(?:-|\/|,|\s)\s*(?:[akqjt2-9])(?:\s*[so])?\b/iu

  @rank_and_suit_phrase ~r/\b(?:ace|king|queen|jack|ten|nine|eight|seven|six|five|four|three|two|10|[2-9]|[jqka])\s+(?:of\s+)?(?:clubs?|diamonds?|hearts?|spades?)\b/iu
  @suit_then_rank_phrase ~r/\b(?:clubs?|diamonds?|hearts?|spades?)\s+(?:ace|king|queen|jack|ten|nine|eight|seven|six|five|four|three|two|10|[2-9]|[jqka])\b/iu

  @hand_strength_term ~r/\b(?:pair|two\s*pair|trips?|set|straight|flush|full\s*house|quads?|kicker|top\s*pair|middle\s*pair|bottom\s*pair|overpair|underpair)\b/iu

  @live_action_strategy_term ~r/\b(?:bet(?:ting)?|check(?:ing)?|call(?:ing)?|raise(?:d|s|ing)?|fold(?:ed|ing)?|bluff(?:ing)?|pot|odds?|equity|range|line|value|position|out\s+of\s+position|in\s+position|early\s+position|late\s+position|button|small\s+blind|big\s+blind|blind|preflop|flop|turn|river|showdown|pay\s+to\s+see|build\s+this\s+pot)\b/iu

  @type decision ::
          :allow
          | {:block,
             :empty | :card_reveal_during_live_hand | :strategy_commentary_during_live_hand}

  @spec evaluate(String.t(), boolean()) :: decision()
  def evaluate(text, hand_live?) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" ->
        {:block, :empty}

      hand_live? and reveals_hole_cards?(trimmed) ->
        {:block, :card_reveal_during_live_hand}

      hand_live? and reveals_strategy_or_hand_strength?(trimmed) ->
        {:block, :strategy_commentary_during_live_hand}

      true ->
        :allow
    end
  end

  def evaluate(_text, _hand_live?), do: {:block, :empty}

  @spec reveals_hole_cards?(String.t()) :: boolean()
  def reveals_hole_cards?(text) when is_binary(text) do
    Regex.match?(@explicit_card, text) or
      Regex.match?(@rank_and_suit_phrase, text) or
      Regex.match?(@suit_then_rank_phrase, text) or
      Regex.match?(@pocket_pair, text) or
      Regex.match?(@two_rank_shorthand, text) or
      Regex.match?(@two_rank_shorthand_spaced, text) or
      (Regex.match?(@hole_context, text) and Regex.match?(@rank_word, text)) or
      Regex.match?(@two_rank_combo, text) or
      (Regex.match?(@hole_context, text) and Regex.match?(@suit_word, text))
  end

  def reveals_hole_cards?(_), do: false

  @spec reveals_strategy_or_hand_strength?(String.t()) :: boolean()
  def reveals_strategy_or_hand_strength?(text) when is_binary(text) do
    Regex.match?(@hand_strength_term, text) or Regex.match?(@live_action_strategy_term, text)
  end

  def reveals_strategy_or_hand_strength?(_), do: false
end

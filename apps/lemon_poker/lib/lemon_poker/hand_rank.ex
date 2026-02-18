defmodule LemonPoker.HandRank do
  @moduledoc """
  Evaluates 5-7 card hold'em hands and compares rankings.
  """

  alias LemonPoker.Card

  @type category ::
          :high_card
          | :pair
          | :two_pair
          | :three_of_a_kind
          | :straight
          | :flush
          | :full_house
          | :four_of_a_kind
          | :straight_flush

  @type t :: %__MODULE__{
          category: category(),
          category_value: 0..8,
          tiebreaker: [integer()],
          best_five: [Card.t()]
        }

  defstruct [:category, :category_value, :tiebreaker, :best_five]

  @category_values %{
    high_card: 0,
    pair: 1,
    two_pair: 2,
    three_of_a_kind: 3,
    straight: 4,
    flush: 5,
    full_house: 6,
    four_of_a_kind: 7,
    straight_flush: 8
  }

  @doc """
  Evaluates a 5-7 card hand and returns the best 5-card rank.
  """
  @spec evaluate([Card.t()]) :: {:ok, t()} | {:error, :invalid_card_count}
  def evaluate(cards) when is_list(cards) and length(cards) in 5..7 do
    best =
      cards
      |> combinations(5)
      |> Enum.map(&evaluate_five!/1)
      |> Enum.max_by(&score_tuple/1)

    {:ok, best}
  end

  def evaluate(_), do: {:error, :invalid_card_count}

  @doc """
  Compares two hand ranks.
  """
  @spec compare(t(), t()) :: :gt | :lt | :eq
  def compare(left, right) do
    left_score = score_tuple(left)
    right_score = score_tuple(right)

    cond do
      left_score > right_score -> :gt
      left_score < right_score -> :lt
      true -> :eq
    end
  end

  defp score_tuple(%__MODULE__{category_value: value, tiebreaker: tiebreaker}) do
    {value, tiebreaker}
  end

  defp evaluate_five!(cards) when length(cards) == 5 do
    values = Enum.map(cards, &Card.rank_value/1)
    suits = Enum.map(cards, & &1.suit)

    sorted_desc = Enum.sort(values, :desc)
    flush? = Enum.uniq(suits) |> length() == 1
    straight_high = straight_high(values)
    counts = value_counts(values)

    cond do
      flush? and not is_nil(straight_high) ->
        rank(:straight_flush, [straight_high], cards)

      has_kind?(counts, 4) ->
        [{quad, _}] = of_kind(counts, 4)
        kicker = counts |> of_kind(1) |> List.first() |> elem(0)
        rank(:four_of_a_kind, [quad, kicker], cards)

      full_house?(counts) ->
        [{trip, _}] = of_kind(counts, 3)
        [{pair, _}] = of_kind(counts, 2)
        rank(:full_house, [trip, pair], cards)

      flush? ->
        rank(:flush, sorted_desc, cards)

      not is_nil(straight_high) ->
        rank(:straight, [straight_high], cards)

      has_kind?(counts, 3) ->
        [{trip, _}] = of_kind(counts, 3)
        kickers = counts |> of_kind(1) |> Enum.map(&elem(&1, 0)) |> Enum.sort(:desc)
        rank(:three_of_a_kind, [trip | kickers], cards)

      two_pair?(counts) ->
        pairs = counts |> of_kind(2) |> Enum.map(&elem(&1, 0)) |> Enum.sort(:desc)
        kicker = counts |> of_kind(1) |> List.first() |> elem(0)
        [high_pair, low_pair] = pairs
        rank(:two_pair, [high_pair, low_pair, kicker], cards)

      has_kind?(counts, 2) ->
        [{pair, _}] = of_kind(counts, 2)
        kickers = counts |> of_kind(1) |> Enum.map(&elem(&1, 0)) |> Enum.sort(:desc)
        rank(:pair, [pair | kickers], cards)

      true ->
        rank(:high_card, sorted_desc, cards)
    end
  end

  defp rank(category, tiebreaker, cards) do
    %__MODULE__{
      category: category,
      category_value: Map.fetch!(@category_values, category),
      tiebreaker: tiebreaker,
      best_five: cards
    }
  end

  defp value_counts(values) do
    values
    |> Enum.frequencies()
    |> Enum.sort_by(fn {value, count} -> {-count, -value} end)
  end

  defp has_kind?(counts, n), do: Enum.any?(counts, fn {_value, count} -> count == n end)

  defp of_kind(counts, n), do: Enum.filter(counts, fn {_value, count} -> count == n end)

  defp full_house?(counts), do: has_kind?(counts, 3) and has_kind?(counts, 2)
  defp two_pair?(counts), do: length(of_kind(counts, 2)) == 2

  defp straight_high(values) do
    unique = values |> Enum.uniq() |> Enum.sort(:desc)

    cond do
      wheel?(unique) ->
        5

      true ->
        straight_high_from_unique(unique)
    end
  end

  defp straight_high_from_unique(values) when length(values) < 5, do: nil

  defp straight_high_from_unique(values) do
    values
    |> Enum.chunk_every(5, 1, :discard)
    |> Enum.find_value(fn window ->
      case window do
        [a, b, c, d, e] when a - 1 == b and b - 1 == c and c - 1 == d and d - 1 == e -> a
        _ -> nil
      end
    end)
  end

  defp wheel?(values) do
    MapSet.subset?(MapSet.new([14, 5, 4, 3, 2]), MapSet.new(values))
  end

  defp combinations(list, size), do: do_combinations(list, size, [])

  defp do_combinations(_, 0, acc), do: [Enum.reverse(acc)]
  defp do_combinations([], _size, _acc), do: []

  defp do_combinations([head | tail], size, acc) do
    with_head = do_combinations(tail, size - 1, [head | acc])
    without_head = do_combinations(tail, size, acc)
    with_head ++ without_head
  end
end

defmodule LemonPoker.Deck do
  @moduledoc """
  Deck utilities with deterministic shuffle support.
  """

  alias LemonPoker.Card

  @type t :: [Card.t()]

  @doc """
  Returns a fresh ordered deck.
  """
  @spec new() :: t()
  def new, do: Card.full_deck()

  @doc """
  Shuffles a deck. Use `seed:` for deterministic order.
  """
  @spec shuffle(t(), keyword()) :: t()
  def shuffle(deck \\ new(), opts \\ []) do
    case Keyword.get(opts, :seed) do
      nil ->
        Enum.shuffle(deck)

      seed ->
        deterministic_shuffle(deck, seed)
    end
  end

  @doc """
  Deals `count` cards from the top of the deck.
  """
  @spec deal(t(), non_neg_integer()) :: {:ok, [Card.t()], t()} | {:error, :not_enough_cards}
  def deal(deck, count) when is_integer(count) and count >= 0 do
    if length(deck) < count do
      {:error, :not_enough_cards}
    else
      {taken, rest} = Enum.split(deck, count)
      {:ok, taken, rest}
    end
  end

  @doc """
  Burns the top card.
  """
  @spec burn(t()) :: {:ok, Card.t(), t()} | {:error, :not_enough_cards}
  def burn(deck) do
    with {:ok, [card], rest} <- deal(deck, 1) do
      {:ok, card, rest}
    end
  end

  @doc """
  Validates that the list is a deduplicated card deck.
  """
  @spec valid?(t()) :: boolean()
  def valid?(deck) when is_list(deck) do
    length(deck) == MapSet.size(MapSet.new(deck)) and Enum.all?(deck, &match?(%Card{}, &1))
  end

  defp deterministic_shuffle(deck, seed) do
    {a, b, c} = normalize_seed(seed)
    state = :rand.seed_s(:exsss, {a, b, c})

    {pairs, _state} =
      Enum.map_reduce(deck, state, fn card, acc ->
        {value, next_acc} = :rand.uniform_s(acc)
        {{value, card}, next_acc}
      end)

    pairs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp normalize_seed(seed) when is_integer(seed) do
    base = abs(seed) + 1
    rem1 = rem(base * 31_415_927, 302_681_999)
    rem2 = rem(base * 77_021_123, 302_681_999)
    rem3 = rem(base * 91_781_223, 302_681_999)
    {max(rem1, 1), max(rem2, 1), max(rem3, 1)}
  end

  defp normalize_seed(seed) do
    normalize_seed(:erlang.phash2(seed, 2_147_483_647))
  end
end

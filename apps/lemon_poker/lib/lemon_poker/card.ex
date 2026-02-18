defmodule LemonPoker.Card do
  @moduledoc """
  Playing card representation for a standard 52-card deck.
  """

  @type rank ::
          :two
          | :three
          | :four
          | :five
          | :six
          | :seven
          | :eight
          | :nine
          | :ten
          | :jack
          | :queen
          | :king
          | :ace
  @type suit :: :clubs | :diamonds | :hearts | :spades
  @type t :: %__MODULE__{rank: rank(), suit: suit()}

  @enforce_keys [:rank, :suit]
  defstruct [:rank, :suit]

  @ranks [
    :two,
    :three,
    :four,
    :five,
    :six,
    :seven,
    :eight,
    :nine,
    :ten,
    :jack,
    :queen,
    :king,
    :ace
  ]
  @suits [:clubs, :diamonds, :hearts, :spades]

  @rank_values @ranks
               |> Enum.with_index(2)
               |> Map.new()

  @rank_chars %{
    "2" => :two,
    "3" => :three,
    "4" => :four,
    "5" => :five,
    "6" => :six,
    "7" => :seven,
    "8" => :eight,
    "9" => :nine,
    "T" => :ten,
    "J" => :jack,
    "Q" => :queen,
    "K" => :king,
    "A" => :ace
  }

  @suit_chars %{"c" => :clubs, "d" => :diamonds, "h" => :hearts, "s" => :spades}

  @reverse_rank_chars Map.new(@rank_chars, fn {char, rank} -> {rank, char} end)
  @reverse_suit_chars Map.new(@suit_chars, fn {char, suit} -> {suit, char} end)

  @doc """
  Builds a card if rank and suit are valid.
  """
  @spec new(rank(), suit()) :: {:ok, t()} | {:error, :invalid_card}
  def new(rank, suit) when rank in @ranks and suit in @suits do
    {:ok, %__MODULE__{rank: rank, suit: suit}}
  end

  def new(_, _), do: {:error, :invalid_card}

  @doc """
  Full 52-card deck in rank/suit canonical order.
  """
  @spec full_deck() :: [t()]
  def full_deck do
    for suit <- @suits, rank <- @ranks do
      %__MODULE__{rank: rank, suit: suit}
    end
  end

  @doc """
  Returns numeric rank value (2..14).
  """
  @spec rank_value(t()) :: 2..14
  def rank_value(%__MODULE__{rank: rank}), do: Map.fetch!(@rank_values, rank)

  @doc """
  Parses short notation like `"As"` or `"Td"`.
  """
  @spec from_string(String.t()) :: {:ok, t()} | {:error, :invalid_card}
  def from_string(<<rank_char::binary-size(1), suit_char::binary-size(1)>>) do
    with rank when not is_nil(rank) <- Map.get(@rank_chars, String.upcase(rank_char)),
         suit when not is_nil(suit) <- Map.get(@suit_chars, String.downcase(suit_char)) do
      {:ok, %__MODULE__{rank: rank, suit: suit}}
    else
      _ -> {:error, :invalid_card}
    end
  end

  def from_string(_), do: {:error, :invalid_card}

  @doc """
  Serializes a card to short notation like `"As"`.
  """
  @spec to_short_string(t()) :: String.t()
  def to_short_string(%__MODULE__{rank: rank, suit: suit}) do
    Map.fetch!(@reverse_rank_chars, rank) <> Map.fetch!(@reverse_suit_chars, suit)
  end
end

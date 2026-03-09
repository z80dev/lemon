defmodule LemonSim.Examples.Skirmish.Rng do
  @moduledoc false

  @modulus 10_000
  @increment 17

  @spec roll(non_neg_integer(), pos_integer()) :: {pos_integer(), non_neg_integer()}
  def roll(seed, sides \\ 100)
      when is_integer(seed) and seed >= 0 and is_integer(sides) and sides > 0 do
    next_seed = rem(seed + @increment, @modulus)
    {rem(next_seed, sides) + 1, next_seed}
  end
end

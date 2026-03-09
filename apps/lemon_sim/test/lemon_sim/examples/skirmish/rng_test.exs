defmodule LemonSim.Examples.Skirmish.RngTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Skirmish.Rng

  test "same seed produces the same roll sequence" do
    seq_a =
      Enum.reduce(1..4, {[], 5}, fn _, {rolls, seed} ->
        {roll, next_seed} = Rng.roll(seed)
        {rolls ++ [roll], next_seed}
      end)
      |> elem(0)

    seq_b =
      Enum.reduce(1..4, {[], 5}, fn _, {rolls, seed} ->
        {roll, next_seed} = Rng.roll(seed)
        {rolls ++ [roll], next_seed}
      end)
      |> elem(0)

    assert seq_a == seq_b
    assert seq_a == [23, 40, 57, 74]
  end
end

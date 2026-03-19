defmodule LemonSim.Examples.WerewolfRolesTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Werewolf.Roles

  test "5-player setup uses one werewolf so the game survives opening night pressure" do
    roles = Roles.role_list(5)

    assert Enum.count(roles, &(&1 == :werewolf)) == 1
    assert Enum.count(roles, &(&1 == :seer)) == 1
    assert Enum.count(roles, &(&1 == :doctor)) == 1
    assert Enum.count(roles, &(&1 == :villager)) == 2
  end

  test "day 1 discussion uses the same multi-round limit as later days" do
    players = %{
      "Alice" => %{role: "villager", status: "alive"},
      "Bram" => %{role: "doctor", status: "alive"},
      "Cora" => %{role: "werewolf", status: "alive"},
      "Dane" => %{role: "seer", status: "alive"},
      "Esme" => %{role: "villager", status: "alive"},
      "Felix" => %{role: "villager", status: "alive"}
    }

    assert Roles.discussion_round_limit(players, 1) == 2
    assert Roles.discussion_round_limit(players, 2) == 2
  end
end

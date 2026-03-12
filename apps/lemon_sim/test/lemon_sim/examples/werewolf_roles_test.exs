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
end

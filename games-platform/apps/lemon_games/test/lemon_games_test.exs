defmodule LemonGamesTest do
  use ExUnit.Case, async: true

  test "application starts" do
    assert Process.whereis(LemonGames.Supervisor) != nil
  end
end

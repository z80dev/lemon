defmodule LemonSimUi.ArenaRedirectController do
  @moduledoc """
  Legacy path aliases for the werewolf arena (`/werewolf` predates the
  generic `/arena/:domain` routes).
  """

  use LemonSimUi, :controller

  def werewolf(conn, _params), do: redirect(conn, to: ~p"/arena/werewolf")

  def werewolf_leaderboard(conn, _params),
    do: redirect(conn, to: ~p"/arena/werewolf/leaderboard")
end

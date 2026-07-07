defmodule LemonSim.Examples.Werewolf.Updaters.Items do
  @moduledoc false

  alias LemonSim.Examples.Werewolf.Roles

  def maybe_distribute_items(players, day_number) do
    if day_number > 1 and :rand.uniform() < 0.4 do
      living = Roles.living_players(players) |> Enum.map(fn {id, _} -> id end)
      lucky_player = Enum.random(living)

      item_pool = [
        {"lantern", "You found an old lantern! Use it at night to see clearly."},
        {"lock", "You found a sturdy lock! Use it to secure your door tonight."},
        {"anonymous_letter",
         "You found blank parchment and a disguised seal! Send an anonymous message."},
        {"wolfsbane", "You found a bundle of wolfsbane! If wolves attack you, you'll survive."}
      ]

      {item_type, description} = Enum.random(item_pool)
      {lucky_player, item_type, description}
    else
      nil
    end
  end

  def remove_first_item(items, item_type) do
    idx =
      Enum.find_index(items, fn i ->
        (Map.get(i, :type) || Map.get(i, "type")) == item_type
      end)

    if idx, do: List.delete_at(items, idx), else: items
  end
end

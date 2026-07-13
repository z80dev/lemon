defmodule LemonSim.Examples.Werewolf.RulesConfig do
  @moduledoc false

  import LemonSim.Examples.Helpers

  @story %{
    schema_version: 1,
    preset: "story",
    private_meetings: true,
    items: true,
    village_events: true,
    evidence: true,
    wandering: true,
    seer_night_one: true
  }

  @classic %{
    schema_version: 1,
    preset: "classic",
    private_meetings: false,
    items: false,
    village_events: false,
    evidence: false,
    wandering: false,
    seer_night_one: true
  }

  def for_preset("story"), do: @story
  def for_preset("classic"), do: @classic
  def for_preset(_preset), do: @story

  def enabled?(world, feature) do
    world
    |> get(:rules, %{})
    |> get(feature, true)
    |> Kernel.!=(false)
  end
end

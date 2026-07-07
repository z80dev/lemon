defmodule LemonSim.Examples.FrameRendererSmokeTest do
  @moduledoc """
  Characterization smoke tests for the non-arena scenario frame renderers.

  Each renderer's `render_frame/2` is exercised against the domain's own
  `initial_world/1`, wrapped in the same `%{type, step, world, events}` shape
  their `GameLog` module writes to disk. This is the first coverage these
  renderers have ever had, so the bar is: render a fresh game state without
  raising and produce a well-formed SVG document that names the game.
  """

  use ExUnit.Case, async: true

  alias LemonSim.Examples.{
    Auction,
    Courtroom,
    Diplomacy,
    DungeonCrawl,
    IntelNetwork,
    Legislature,
    MurderMystery,
    Pandemic,
    Skirmish,
    StartupIncubator,
    SupplyChain
  }

  @domains [
    {Auction, Auction.FrameRenderer, "AUCTION HOUSE"},
    {Courtroom, Courtroom.FrameRenderer, "COURT OF LAW"},
    {Diplomacy, Diplomacy.FrameRenderer, "DIPLOMACY"},
    {DungeonCrawl, DungeonCrawl.FrameRenderer, "DUNGEON CRAWL"},
    {IntelNetwork, IntelNetwork.FrameRenderer, "INTELLIGENCE NETWORK"},
    {Legislature, Legislature.FrameRenderer, "LEGISLATURE"},
    {MurderMystery, MurderMystery.FrameRenderer, "MURDER MYSTERY"},
    {Pandemic, Pandemic.FrameRenderer, "PANDEMIC RESPONSE"},
    {Skirmish, Skirmish.FrameRenderer, "LEMON SKIRMISH"},
    {StartupIncubator, StartupIncubator.FrameRenderer, "STARTUP INCUBATOR"},
    {SupplyChain, SupplyChain.FrameRenderer, "SUPPLY CHAIN"}
  ]

  for {domain, renderer, title} <- @domains do
    test "#{inspect(domain)} renders a valid, titled SVG frame from its initial world" do
      domain = unquote(domain)
      renderer = unquote(renderer)
      title = unquote(title)

      world = domain.initial_world()
      entry = %{type: "init", step: 0, world: world, events: []}

      svg = renderer.render_frame(entry, width: 640, height: 360)

      assert is_binary(svg)
      assert String.starts_with?(svg, "<svg")
      assert String.ends_with?(svg, "</svg>")
      assert svg =~ title
    end
  end
end

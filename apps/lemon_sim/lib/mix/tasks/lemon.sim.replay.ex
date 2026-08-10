defmodule Mix.Tasks.Lemon.Sim.Replay do
  use Mix.Task

  @shortdoc "Generate a video replay from any scenario game log"

  # scenario name => that scenario's VideoGenerator module. Every value `use`s
  # LemonSim.Examples.Rendering.DomainVideoGenerator, so they all expose the same
  # generate/2 and check_dependencies/0 interface.
  @generators %{
    "skirmish" => LemonSim.Examples.Skirmish.VideoGenerator,
    "auction" => LemonSim.Examples.Auction.VideoGenerator,
    "courtroom" => LemonSim.Examples.Courtroom.VideoGenerator,
    "diplomacy" => LemonSim.Examples.Diplomacy.VideoGenerator,
    "dungeon_crawl" => LemonSim.Examples.DungeonCrawl.VideoGenerator,
    "intel_network" => LemonSim.Examples.IntelNetwork.VideoGenerator,
    "legislature" => LemonSim.Examples.Legislature.VideoGenerator,
    "murder_mystery" => LemonSim.Examples.MurderMystery.VideoGenerator,
    "pandemic" => LemonSim.Examples.Pandemic.VideoGenerator,
    "poker" => LemonSim.Examples.Poker.VideoGenerator,
    "space_station" => LemonSim.Examples.SpaceStation.VideoGenerator,
    "startup_incubator" => LemonSim.Examples.StartupIncubator.VideoGenerator,
    "stock_market" => LemonSim.Examples.StockMarket.VideoGenerator,
    "supply_chain" => LemonSim.Examples.SupplyChain.VideoGenerator,
    "survivor" => LemonSim.Examples.Survivor.VideoGenerator,
    "werewolf" => LemonSim.Examples.Werewolf.VideoGenerator
  }

  @moduledoc """
  Generates a video replay from any scenario's JSONL game log.

  This one task replaces the former per-scenario `mix lemon.sim.<scenario>_replay`
  tasks. (VendingBench keeps its own `mix lemon.sim.vending_bench_replay`, which
  builds a static HTML browser rather than a video.)

  ## Usage

      mix lemon.sim.replay <scenario> path/to/game.jsonl [options]

  A single positional argument is treated as a skirmish log for backwards
  compatibility (`mix lemon.sim.replay path/to/game.jsonl`).

  ## Scenarios

  `skirmish`, `auction`, `courtroom`, `diplomacy`, `dungeon_crawl`,
  `intel_network`, `legislature`, `murder_mystery`, `pandemic`, `poker`,
  `space_station`, `startup_incubator`, `stock_market`, `supply_chain`,
  `survivor`, `werewolf`.

  ## Options

    * `--output` - Output video path (default: derived from input, e.g. game.mp4)
    * `--fps` - Frames per second (default: 2)
    * `--hold-frames` - Base hold count per entry / pacing multiplier (default: 1)
    * `--width` - Frame width in pixels (default: 1920)
    * `--height` - Frame height in pixels (default: 1080)
    * `--keep-frames` - Keep intermediate SVG/PNG files for inspection
    * `--help` - Show this help

  ## Examples

      mix lemon.sim.replay poker apps/lemon_sim/priv/game_logs/poker/abc.jsonl
      mix lemon.sim.replay werewolf werewolf.jsonl --fps 3 --output werewolf.mp4
      mix lemon.sim.replay priv/game_logs/abc123.jsonl   # skirmish (back-compat)

  ## Requirements

  Requires `rsvg-convert` and `ffmpeg` on your PATH.

      macOS:  brew install librsvg ffmpeg
      Linux:  apt-get install librsvg2-bin ffmpeg
  """

  @switches [
    output: :string,
    fps: :integer,
    hold_frames: :integer,
    width: :integer,
    height: :integer,
    keep_frames: :boolean,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        {scenario, log_path} = parse_positionals(argv)
        generate(scenario, log_path, opts)
    end
  end

  # Two positionals: <scenario> <log>. One positional: back-compat skirmish log,
  # unless it is a bare scenario name (then the log path is missing).
  defp parse_positionals([scenario, log_path | _]), do: {scenario, log_path}

  defp parse_positionals([only]) do
    if Map.has_key?(@generators, only) do
      Mix.raise("missing log path\n\nUsage: mix lemon.sim.replay #{only} path/to/game.jsonl")
    else
      {"skirmish", only}
    end
  end

  defp parse_positionals([]) do
    Mix.raise(
      "missing arguments\n\nUsage: mix lemon.sim.replay <scenario> path/to/game.jsonl\n\nScenarios: #{scenarios_list()}"
    )
  end

  defp generate(scenario, log_path, opts) do
    generator =
      Map.get(@generators, scenario) ||
        Mix.raise("unknown scenario #{inspect(scenario)}\n\nScenarios: #{scenarios_list()}")

    unless File.exists?(log_path) do
      Mix.raise("file not found: #{log_path}")
    end

    ensure_dependencies!(generator)

    gen_opts =
      []
      |> maybe_put(:output, opts[:output])
      |> maybe_put(:fps, opts[:fps])
      |> maybe_put(:hold_frames, opts[:hold_frames])
      |> maybe_put(:width, opts[:width])
      |> maybe_put(:height, opts[:height])
      |> maybe_put(:keep_frames, opts[:keep_frames])

    case generator.generate(log_path, gen_opts) do
      {:ok, video_path} ->
        size = File.stat!(video_path).size

        Mix.shell().info(
          "#{scenario} replay video generated: #{video_path} (#{format_file_size(size)})"
        )

      {:error, reason} ->
        Mix.raise("video generation failed: #{inspect(reason)}")
    end
  end

  defp ensure_dependencies!(generator) do
    case generator.check_dependencies() do
      :ok ->
        :ok

      {:error, {:missing_tools, tools}} ->
        Mix.raise(
          "missing required tools: #{Enum.join(tools, ", ")}\n\n" <>
            "Install them with:\n" <>
            "  macOS:  brew install librsvg ffmpeg\n" <>
            "  Linux:  apt-get install librsvg2-bin ffmpeg"
        )
    end
  end

  defp scenarios_list, do: @generators |> Map.keys() |> Enum.sort() |> Enum.join(", ")

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end

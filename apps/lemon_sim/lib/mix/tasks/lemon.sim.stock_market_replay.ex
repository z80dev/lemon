defmodule Mix.Tasks.Lemon.Sim.StockMarketReplay do
  @shortdoc "Generates a video replay from a Stock Market game log"
  @moduledoc """
  Renders a Stock Market game transcript (JSONL) into an MP4 video.

  ## Usage

      mix lemon.sim.stock_market_replay path/to/stock_market.jsonl [options]

  ## Options

    * `--output` - Output video path (default: same as input with .mp4 extension)
    * `--fps` - Frames per second (default: 2)
    * `--hold-frames` - Base frame duplication for pacing (default: 1)
    * `--width` - Frame width (default: 1920)
    * `--height` - Frame height (default: 1080)
    * `--keep-frames` - Keep intermediate SVG/PNG files
    * `--help` - Show this help

  ## Prerequisites

  Requires `rsvg-convert` (from librsvg) and `ffmpeg`:

      brew install librsvg ffmpeg   # macOS
  """

  use Mix.Task

  alias LemonSim.Examples.StockMarket.VideoGenerator

  @switches [
    output: :string,
    fps: :integer,
    hold_frames: :integer,
    width: :integer,
    height: :integer,
    keep_frames: :boolean,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, switches: @switches)
    cond do
      Keyword.get(opts, :help, false) -> Mix.shell().info(@moduledoc)
      positional == [] ->
        Mix.shell().error("Usage: mix lemon.sim.stock_market_replay <path.jsonl> [options]")
        Mix.shell().error("Run with --help for details.")
      true ->
        log_path = List.first(positional)
        do_generate(log_path, opts)
    end
  end

  defp do_generate(log_path, opts) do
    Mix.shell().info("Generating Stock Market replay from #{log_path}...")
    gen_opts = []
      |> maybe_put(:output, Keyword.get(opts, :output))
      |> maybe_put(:fps, Keyword.get(opts, :fps))
      |> maybe_put(:hold_frames, Keyword.get(opts, :hold_frames))
      |> maybe_put(:width, Keyword.get(opts, :width))
      |> maybe_put(:height, Keyword.get(opts, :height))
      |> maybe_put(:keep_frames, Keyword.get(opts, :keep_frames))

    case VideoGenerator.generate(log_path, gen_opts) do
      {:ok, video_path} ->
        file_size = File.stat!(video_path).size
        Mix.shell().info("Replay video: #{video_path} (#{format_file_size(file_size)})")
      {:error, {:missing_tools, tools}} ->
        Mix.shell().error("Missing required tools: #{Enum.join(tools, ", ")}")
        Mix.shell().error("Install with: brew install librsvg ffmpeg")
      {:error, {:file_not_found, path}} ->
        Mix.shell().error("Log file not found: #{path}")
      {:error, reason} ->
        Mix.shell().error("Failed to generate replay: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end

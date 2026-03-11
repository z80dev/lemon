defmodule Mix.Tasks.Lemon.Sim.Replay do
  use Mix.Task

  @shortdoc "Generate a video replay from a skirmish game log"

  @moduledoc """
  Generates a video replay from a skirmish game log.

  ## Usage

      mix lemon.sim.replay path/to/game.jsonl [options]

  ## Options

    * `--output` - Output video path (default: derived from input, e.g., game.mp4)
    * `--fps` - Frames per second (default: 2)
    * `--width` - Frame width in pixels (default: 1920)
    * `--height` - Frame height in pixels (default: 1080)
    * `--keep-frames` - Keep intermediate SVG/PNG files for inspection
    * `--help` - Show this help

  ## Examples

      mix lemon.sim.replay priv/game_logs/abc123.jsonl
      mix lemon.sim.replay priv/game_logs/abc123.jsonl --output replay.mp4 --fps 4
      mix lemon.sim.replay priv/game_logs/abc123.jsonl --keep-frames --width 1280 --height 720

  ## Requirements

  This task requires `rsvg-convert` and `ffmpeg` to be installed and available on
  your PATH.

  On macOS:

      brew install librsvg ffmpeg

  On Ubuntu/Debian:

      apt-get install librsvg2-bin ffmpeg
  """

  alias LemonSim.Examples.Skirmish.VideoGenerator

  @switches [
    output: :string,
    fps: :integer,
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

      argv == [] ->
        Mix.raise("missing required argument: path to game log file\n\nUsage: mix lemon.sim.replay path/to/game.jsonl [options]")

      true ->
        [log_path | _] = argv

        unless File.exists?(log_path) do
          Mix.raise("file not found: #{log_path}")
        end

        case VideoGenerator.check_dependencies() do
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

        gen_opts =
          []
          |> maybe_put(:output, opts[:output])
          |> maybe_put(:fps, opts[:fps])
          |> maybe_put(:width, opts[:width])
          |> maybe_put(:height, opts[:height])
          |> maybe_put(:keep_frames, opts[:keep_frames])

        case VideoGenerator.generate(log_path, gen_opts) do
          {:ok, video_path} ->
            file_size = File.stat!(video_path).size
            Mix.shell().info("Replay video generated: #{video_path} (#{format_file_size(file_size)})")

          {:error, reason} ->
            Mix.raise("video generation failed: #{inspect(reason)}")
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end

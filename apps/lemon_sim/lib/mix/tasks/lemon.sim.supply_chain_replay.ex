defmodule Mix.Tasks.Lemon.Sim.SupplyChainReplay do
  use Mix.Task

  @shortdoc "Render a Supply Chain JSONL game log into a video"

  @moduledoc """
  Renders a Supply Chain simulation JSONL game log into an MP4 video.

  Requires `rsvg-convert` and `ffmpeg` to be installed.

      mix lemon.sim.supply_chain_replay priv/game_logs/supply_chain_abc123.jsonl
      mix lemon.sim.supply_chain_replay game.jsonl --output replay.mp4 --fps 3
      mix lemon.sim.supply_chain_replay game.jsonl --keep-frames
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
        print_help()

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      argv == [] ->
        Mix.raise("supply_chain_replay requires a log file path argument")

      true ->
        [log_path | _] = argv

        unless File.exists?(log_path) do
          Mix.raise("log file not found: #{log_path}")
        end

        generate_opts =
          []
          |> maybe_put(:output, opts[:output])
          |> maybe_put(:fps, opts[:fps])
          |> maybe_put(:hold_frames, opts[:hold_frames])
          |> maybe_put(:width, opts[:width])
          |> maybe_put(:height, opts[:height])
          |> maybe_put(:keep_frames, opts[:keep_frames])

        case LemonSim.Examples.SupplyChain.VideoGenerator.generate(log_path, generate_opts) do
          {:ok, output_path} ->
            Mix.shell().info("Video written to: #{output_path}")

          {:error, {:missing_tools, tools}} ->
            Mix.raise(
              "Missing required tools: #{Enum.join(tools, ", ")}. " <>
                "Install rsvg-convert (librsvg) and ffmpeg."
            )

          {:error, {:file_not_found, path}} ->
            Mix.raise("Log file not found: #{path}")

          {:error, reason} ->
            Mix.raise("Replay generation failed: #{inspect(reason)}")
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.supply_chain_replay LOG_PATH [options]

    Arguments:
      LOG_PATH                     Path to the JSONL game log file

    Options:
      --output PATH                Output video path (default: derived from log path)
      --fps N                      Frames per second (default: 2)
      --hold-frames N              Base frame repeat count for pacing (default: 1)
      --width N                    Video width in pixels (default: 1920)
      --height N                   Video height in pixels (default: 1080)
      --keep-frames                Keep intermediate SVG/PNG frames after rendering
      --help                       Show this help

    Requirements:
      rsvg-convert (librsvg)       For SVG-to-PNG conversion
      ffmpeg                       For video encoding
    """)
  end
end

defmodule Mix.Tasks.Lemon.Sim.IntelNetworkReplay do
  use Mix.Task

  @shortdoc "Generate a replay video from an Intelligence Network JSONL log"

  @moduledoc """
  Generates a video replay from an Intelligence Network JSONL game log.

  Requires `rsvg-convert` and `ffmpeg` to be installed.

      mix lemon.sim.intel_network_replay priv/game_logs/intel_network_abc123.jsonl
      mix lemon.sim.intel_network_replay game.jsonl --output replay.mp4 --fps 3
      mix lemon.sim.intel_network_replay game.jsonl --keep-frames
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
        Mix.raise("usage: mix lemon.sim.intel_network_replay PATH_TO_JSONL_LOG [options]")

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

        Mix.shell().info("Generating replay from #{log_path}...")

        case LemonSim.Examples.IntelNetwork.VideoGenerator.generate(log_path, generate_opts) do
          {:ok, output_path} ->
            Mix.shell().info("Replay video saved to #{output_path}")

          {:error, {:missing_tools, tools}} ->
            Mix.raise(
              "Missing required tools: #{Enum.join(tools, ", ")}. " <>
                "Install rsvg-convert (librsvg) and ffmpeg to generate videos."
            )

          {:error, reason} ->
            Mix.raise("Replay generation failed: #{inspect(reason)}")
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.intel_network_replay PATH [options]

    Arguments:
      PATH                         Path to a .jsonl game log file

    Options:
      --output PATH                Output video path (default: <log>.mp4)
      --fps N                      Frames per second (default: 2)
      --hold-frames N              Base frame duplication multiplier (default: 1)
      --width N                    Frame width in pixels (default: 1920)
      --height N                   Frame height in pixels (default: 1080)
      --keep-frames                Keep intermediate SVG/PNG frames
      --help                       Show this help

    Requirements:
      - rsvg-convert (from librsvg2-bin package)
      - ffmpeg
    """)
  end
end

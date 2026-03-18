defmodule Mix.Tasks.Lemon.Sim.StartupIncubatorReplay do
  use Mix.Task

  @shortdoc "Generate a video replay from a Startup Incubator JSONL log"

  @moduledoc """
  Generates a gameplay video from a previously recorded Startup Incubator JSONL log.

  Requires `rsvg-convert` (librsvg) and `ffmpeg` to be installed.

      mix lemon.sim.startup_incubator_replay priv/game_logs/startup_incubator_abc123.jsonl
      mix lemon.sim.startup_incubator_replay game.jsonl --output replay.mp4 --fps 3
      mix lemon.sim.startup_incubator_replay game.jsonl --width 1280 --height 720 --keep-frames
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
        Mix.raise("usage: mix lemon.sim.startup_incubator_replay PATH_TO_LOG [options]")

      true ->
        [log_path | _] = argv

        unless File.exists?(log_path) do
          Mix.raise("log file not found: #{log_path}")
        end

        case LemonSim.Examples.StartupIncubator.VideoGenerator.check_dependencies() do
          {:error, {:missing_tools, tools}} ->
            Mix.raise(
              "missing required tools: #{Enum.join(tools, ", ")}. " <>
                "Install rsvg-convert (librsvg) and ffmpeg."
            )

          :ok ->
            :ok
        end

        generate_opts =
          []
          |> maybe_put(:output, opts[:output])
          |> maybe_put(:fps, opts[:fps])
          |> maybe_put(:hold_frames, opts[:hold_frames])
          |> maybe_put(:width, opts[:width])
          |> maybe_put(:height, opts[:height])
          |> maybe_put(:keep_frames, opts[:keep_frames])

        case LemonSim.Examples.StartupIncubator.VideoGenerator.generate(log_path, generate_opts) do
          {:ok, output_path} ->
            Mix.shell().info("Video saved to: #{output_path}")

          {:error, reason} ->
            Mix.raise("video generation failed: #{inspect(reason)}")
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.startup_incubator_replay LOG_PATH [options]

    Arguments:
      LOG_PATH                     Path to the .jsonl log file

    Options:
      --output PATH                Output video path (default: <log_path>.mp4)
      --fps N                      Frames per second (default: 2)
      --hold-frames N              Base frame duplication for pacing (default: 1)
      --width N                    Frame width in pixels (default: 1920)
      --height N                   Frame height in pixels (default: 1080)
      --keep-frames                Keep intermediate SVG/PNG files
      --help                       Show this help

    Dependencies:
      rsvg-convert (librsvg)       SVG -> PNG conversion
      ffmpeg                       PNG sequence -> MP4 encoding
    """)
  end
end

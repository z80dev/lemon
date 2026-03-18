defmodule Mix.Tasks.Lemon.Sim.PandemicReplay do
  use Mix.Task

  @shortdoc "Generate a video replay from a Pandemic Response JSONL log"

  @moduledoc """
  Generates a video replay from a Pandemic Response JSONL log file.

  Requires `rsvg-convert` and `ffmpeg` to be installed.

      mix lemon.sim.pandemic_replay priv/game_logs/pandemic_abc123.jsonl
      mix lemon.sim.pandemic_replay priv/game_logs/pandemic_abc123.jsonl --output /tmp/pandemic.mp4
      mix lemon.sim.pandemic_replay priv/game_logs/pandemic_abc123.jsonl --fps 3 --keep-frames
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
        Mix.raise("usage: mix lemon.sim.pandemic_replay <log_path> [options]")

      true ->
        [log_path | _] = argv

        generate_opts =
          []
          |> maybe_put(:output, opts[:output])
          |> maybe_put(:fps, opts[:fps])
          |> maybe_put(:hold_frames, opts[:hold_frames])
          |> maybe_put(:width, opts[:width])
          |> maybe_put(:height, opts[:height])
          |> maybe_put(:keep_frames, opts[:keep_frames])

        case LemonSim.Examples.Pandemic.VideoGenerator.generate(log_path, generate_opts) do
          {:ok, output_path} ->
            Mix.shell().info("Video generated: #{output_path}")

          {:error, {:missing_tools, tools}} ->
            Mix.raise(
              "Missing required tools: #{Enum.join(tools, ", ")}. " <>
                "Install rsvg-convert (librsvg) and ffmpeg."
            )

          {:error, {:file_not_found, path}} ->
            Mix.raise("Log file not found: #{path}")

          {:error, reason} ->
            Mix.raise("Failed to generate video: #{inspect(reason)}")
        end
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_help do
    Mix.shell().info("""
    mix lemon.sim.pandemic_replay <log_path> [options]

    Generates a video replay from a Pandemic Response JSONL log file.
    Requires: rsvg-convert (librsvg) and ffmpeg.

    Arguments:
      log_path             Path to the JSONL log file

    Options:
      --output PATH        Output video path (default: <log_path>.mp4)
      --fps N              Frames per second (default: 2)
      --hold-frames N      Base frame hold count (default: 1)
      --width N            Frame width in pixels (default: 1920)
      --height N           Frame height in pixels (default: 1080)
      --keep-frames        Keep intermediate SVG/PNG frames
      --help               Show this help
    """)
  end
end

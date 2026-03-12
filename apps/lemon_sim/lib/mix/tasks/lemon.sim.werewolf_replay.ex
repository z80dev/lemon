defmodule Mix.Tasks.Lemon.Sim.WerewolfReplay do
  use Mix.Task

  @shortdoc "Generate a video replay from a Werewolf game transcript"

  @moduledoc """
  Generates a video replay from a Werewolf game transcript.

  ## Usage

      mix lemon.sim.werewolf_replay path/to/transcript.jsonl [options]

  ## Options

    * `--output` - Output video path (default: derived from input)
    * `--fps` - Frames per second (default: 2)
    * `--hold-frames` - Replay pacing multiplier for scene dwell time (default: 1)
    * `--width` - Frame width in pixels (default: 1920)
    * `--height` - Frame height in pixels (default: 1080)
    * `--keep-frames` - Keep intermediate SVG/PNG files
    * `--help` - Show this help

  ## Examples

      mix lemon.sim.werewolf_replay apps/lemon_sim/priv/game_logs/werewolf_4model.jsonl
      mix lemon.sim.werewolf_replay werewolf.jsonl --fps 3 --output werewolf_replay.mp4
  """

  alias LemonSim.Examples.Werewolf.VideoGenerator

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

      argv == [] ->
        Mix.raise(
          "missing argument: path to transcript file\n\nUsage: mix lemon.sim.werewolf_replay path/to/transcript.jsonl"
        )

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
              "missing required tools: #{Enum.join(tools, ", ")}\n" <>
                "Install: brew install librsvg ffmpeg"
            )
        end

        gen_opts =
          []
          |> maybe_put(:output, opts[:output])
          |> maybe_put(:fps, opts[:fps])
          |> maybe_put(:hold_frames, opts[:hold_frames])
          |> maybe_put(:width, opts[:width])
          |> maybe_put(:height, opts[:height])
          |> maybe_put(:keep_frames, opts[:keep_frames])

        case VideoGenerator.generate(log_path, gen_opts) do
          {:ok, video_path} ->
            file_size = File.stat!(video_path).size
            Mix.shell().info("Werewolf replay: #{video_path} (#{format_file_size(file_size)})")

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

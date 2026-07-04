defmodule LemonSim.Examples.SpaceStation.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Rendering.VideoGenerator
  alias LemonSim.Examples.Rendering.VideoGenerator.Config
  alias LemonSim.Examples.SpaceStation.{FrameRenderer, ReplayStoryboard}

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(log_path, opts \\ []) do
    VideoGenerator.generate(config(), log_path, opts)
  end

  @spec check_dependencies() :: :ok | {:error, {:missing_tools, [String.t()]}}
  def check_dependencies do
    VideoGenerator.check_dependencies()
  end

  defp config do
    %Config{
      frame_renderer: FrameRenderer,
      dir_name: "lemon_space_station_replay",
      read_entries: &read_transcript/1,
      read_message: "Built",
      read_subject: "replay beats",
      build_frames: fn entries, opts ->
        entries
        |> ReplayStoryboard.build(
          fps: Keyword.fetch!(opts, :fps),
          hold_frames: Keyword.fetch!(opts, :hold_frames)
        )
        |> Enum.map(fn %{entry: entry, hold_frames: hold_frames} ->
          %{entry: entry, hold_frames: hold_frames}
        end)
      end
    }
  end

  defp read_transcript(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end
end

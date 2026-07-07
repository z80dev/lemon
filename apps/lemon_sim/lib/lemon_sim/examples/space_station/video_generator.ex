defmodule LemonSim.Examples.SpaceStation.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.SpaceStation.{FrameRenderer, ReplayStoryboard}

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
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

  defp read_transcript(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end
end

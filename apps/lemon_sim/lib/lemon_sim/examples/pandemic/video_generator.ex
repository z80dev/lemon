defmodule LemonSim.Examples.Pandemic.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Pandemic.{FrameRenderer, GameLog}
  alias LemonSim.Examples.Rendering.FrameChrome
  alias LemonSim.Examples.Rendering.VideoGenerator
  alias LemonSim.Examples.Rendering.VideoGenerator.Config

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
      dir_name: "lemon_pandemic_replay",
      read_entries: &GameLog.read_log/1,
      build_frames: fn entries, opts ->
        VideoGenerator.default_frames(entries, opts, &hold_count_for/2)
      end
    }
  end

  defp hold_count_for(entry, base_hold) do
    type = FrameChrome.get(entry, "type", "step")
    events = FrameChrome.get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 5
        has_event?(events, "deaths_recorded") -> 3
        has_event?(events, "round_advanced") -> 2
        has_event?(events, "spread_occurred") -> 2
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind), do: FrameChrome.has_event?(events, kind)
end

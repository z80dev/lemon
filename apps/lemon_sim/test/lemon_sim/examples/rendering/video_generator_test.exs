defmodule LemonSim.Examples.Rendering.VideoGeneratorTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Rendering.VideoGenerator
  alias LemonSim.Examples.Rendering.VideoGenerator.Config

  test "build_frames dispatches through scenario config" do
    config = %Config{
      frame_renderer: __MODULE__,
      dir_name: "lemon_test_replay",
      read_entries: fn _path -> [] end,
      build_frames: fn entries, opts ->
        VideoGenerator.default_frames(entries, opts, fn entry, base ->
          base * Map.fetch!(entry, :multiplier)
        end)
      end
    }

    assert VideoGenerator.build_frames(config, [%{multiplier: 2}, %{multiplier: 3}],
             hold_frames: 4
           ) == [
             %{entry: %{multiplier: 2}, hold_frames: 8},
             %{entry: %{multiplier: 3}, hold_frames: 12}
           ]
  end

  def render_frame(_entry, _opts), do: ""
end

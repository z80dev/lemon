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

  defmodule Dummy do
    @moduledoc false
    use LemonSim.Examples.Rendering.DomainVideoGenerator,
      frame_renderer: __MODULE__,
      dir_name: "lemon_dummy_replay",
      read_entries: fn _path -> [] end

    defp hold_count_for(entry, base_hold), do: base_hold * Map.fetch!(entry, :multiplier)

    def render_frame(_entry, _opts), do: ""
    def config_for_test, do: config()
  end

  describe "DomainVideoGenerator" do
    test "generates the generate/2 and check_dependencies/0 delegates" do
      assert function_exported?(Dummy, :generate, 2)
      assert function_exported?(Dummy, :check_dependencies, 0)
    end

    test "wires dir_name, frame_renderer, and the local hold_count_for/2 into config/0" do
      config = Dummy.config_for_test()

      assert %Config{} = config
      assert config.dir_name == "lemon_dummy_replay"
      assert config.frame_renderer == Dummy
      assert config.read_message == "Read"
      assert config.read_subject == "log entries"

      assert VideoGenerator.build_frames(config, [%{multiplier: 2}, %{multiplier: 3}],
               hold_frames: 4
             ) == [
               %{entry: %{multiplier: 2}, hold_frames: 8},
               %{entry: %{multiplier: 3}, hold_frames: 12}
             ]
    end

    test "real domain video generators still expose the shared public API" do
      domains = [
        LemonSim.Examples.Poker.VideoGenerator,
        LemonSim.Examples.Survivor.VideoGenerator,
        LemonSim.Examples.Werewolf.VideoGenerator,
        LemonSim.Examples.SpaceStation.VideoGenerator,
        LemonSim.Examples.Skirmish.VideoGenerator
      ]

      for mod <- domains do
        Code.ensure_loaded!(mod)

        assert function_exported?(mod, :generate, 2), "#{inspect(mod)} should export generate/2"

        assert function_exported?(mod, :check_dependencies, 0),
               "#{inspect(mod)} should export check_dependencies/0"
      end
    end
  end
end

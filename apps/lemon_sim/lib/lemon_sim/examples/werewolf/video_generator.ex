defmodule LemonSim.Examples.Werewolf.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Rendering.FrameChrome
  alias LemonSim.Examples.Rendering.VideoGenerator
  alias LemonSim.Examples.Rendering.VideoGenerator.Config
  alias LemonSim.Examples.Werewolf.{FrameRenderer, ReplayStoryboard}

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
      dir_name: "lemon_werewolf_replay",
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
      end,
      init_render_state: &init_render_state/1,
      render_opts: &render_opts/3
    }
  end

  defp read_transcript(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp init_render_state(frames) do
    entries = Enum.map(frames, & &1.entry)
    %{players: extract_players_info(entries), elimination_log: []}
  end

  defp render_opts(entry, state, opts) do
    elimination_log = update_elim_log(state.elimination_log, entry)

    frame_opts =
      opts
      |> Keyword.put(:players, state.players)
      |> Keyword.put(:elimination_log, elimination_log)

    {frame_opts, %{state | elimination_log: elimination_log}}
  end

  defp extract_players_info(entries) do
    case Enum.find(entries, fn entry -> FrameChrome.get(entry, :type, "") == "game_start" end) do
      nil -> %{}
      start -> FrameChrome.get(start, :players, %{})
    end
  end

  defp update_elim_log(current, entry) do
    case FrameChrome.get(entry, :elimination_log, nil) do
      log when is_list(log) and log != [] -> log
      _ -> current
    end
  end
end

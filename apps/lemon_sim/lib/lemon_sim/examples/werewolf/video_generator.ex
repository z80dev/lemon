defmodule LemonSim.Examples.Werewolf.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Werewolf.{FrameRenderer, ReplayStoryboard}

  @default_fps 2
  @default_hold_frames 1
  @default_width 1920
  @default_height 1080

  @spec generate(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(log_path, opts \\ []) do
    with :ok <- check_dependencies(),
         :ok <- validate_input(log_path) do
      output = Keyword.get(opts, :output, derive_output_path(log_path))
      fps = Keyword.get(opts, :fps, @default_fps)
      hold_frames = Keyword.get(opts, :hold_frames, @default_hold_frames)
      width = Keyword.get(opts, :width, @default_width)
      height = Keyword.get(opts, :height, @default_height)
      keep_frames = Keyword.get(opts, :keep_frames, false)

      render_opts = [width: width, height: height]
      tmp_dir = create_temp_dir()

      try do
        entries = read_transcript(log_path)
        beats = ReplayStoryboard.build(entries, fps: fps, hold_frames: hold_frames)
        total = length(beats)

        IO.puts("Built #{total} replay beats from #{log_path}")

        frame_index = render_all_frames(beats, tmp_dir, render_opts, total)

        IO.puts("Converting #{frame_index} frames to PNG...")
        :ok = convert_svgs_to_pngs(tmp_dir, frame_index, width, height)

        IO.puts("Encoding video...")
        :ok = encode_video(tmp_dir, fps, output)

        file_size = File.stat!(output).size
        IO.puts("Video written to #{output} (#{format_file_size(file_size)})")

        {:ok, output}
      after
        unless keep_frames do
          File.rm_rf!(tmp_dir)
        end
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec check_dependencies() :: :ok | {:error, {:missing_tools, [String.t()]}}
  def check_dependencies do
    required = ["rsvg-convert", "ffmpeg"]

    missing =
      Enum.reject(required, fn tool ->
        case System.find_executable(tool) do
          nil -> false
          _path -> true
        end
      end)

    case missing do
      [] -> :ok
      tools -> {:error, {:missing_tools, tools}}
    end
  end

  # -- Private --

  defp validate_input(log_path) do
    if File.exists?(log_path), do: :ok, else: {:error, {:file_not_found, log_path}}
  end

  defp derive_output_path(log_path) do
    log_path |> Path.rootname() |> Kernel.<>(".mp4")
  end

  defp create_temp_dir do
    dir_name = "lemon_werewolf_replay_#{System.system_time(:millisecond)}"
    dir = Path.join(System.tmp_dir!(), dir_name)
    File.mkdir_p!(dir)
    dir
  end

  defp read_transcript(path) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  defp render_all_frames(beats, tmp_dir, render_opts, total) do
    players_info = extract_players_info(Enum.map(beats, & &1.entry))

    {final_index, _, _} =
      Enum.reduce(beats, {1, 1, []}, fn %{entry: entry, hold_frames: hold_count},
                                        {frame_index, entry_num, elim_log} ->
        IO.puts("Rendering frame #{entry_num}/#{total}...")

        # Update elimination log from this entry
        elim_log = update_elim_log(elim_log, entry)

        frame_opts =
          render_opts
          |> Keyword.put(:players, players_info)
          |> Keyword.put(:elimination_log, elim_log)

        svg = FrameRenderer.render_frame(entry, frame_opts)

        new_index =
          Enum.reduce(1..hold_count, frame_index, fn _i, idx ->
            path = frame_path(tmp_dir, idx, "svg")
            File.write!(path, svg)
            idx + 1
          end)

        {new_index, entry_num + 1, elim_log}
      end)

    final_index - 1
  end

  defp extract_players_info(entries) do
    case Enum.find(entries, fn e -> get(e, :type, "") == "game_start" end) do
      nil -> %{}
      start -> get(start, :players, %{})
    end
  end

  defp update_elim_log(current, entry) do
    case get(entry, :elimination_log, nil) do
      log when is_list(log) and log != [] -> log
      _ -> current
    end
  end

  defp frame_path(tmp_dir, index, extension) do
    filename = "frame_#{String.pad_leading(Integer.to_string(index), 4, "0")}.#{extension}"
    Path.join(tmp_dir, filename)
  end

  defp convert_svgs_to_pngs(tmp_dir, frame_count, width, height) do
    Enum.each(1..frame_count, fn index ->
      svg_path = frame_path(tmp_dir, index, "svg")
      png_path = frame_path(tmp_dir, index, "png")

      {_, 0} =
        System.cmd("rsvg-convert", [
          "-w",
          Integer.to_string(width),
          "-h",
          Integer.to_string(height),
          svg_path,
          "-o",
          png_path
        ])
    end)

    :ok
  end

  defp encode_video(tmp_dir, fps, output) do
    input_pattern = Path.join(tmp_dir, "frame_%04d.png")
    output_abs = Path.expand(output)

    {_, 0} =
      System.cmd("ffmpeg", [
        "-y",
        "-framerate",
        Integer.to_string(fps),
        "-i",
        input_pattern,
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-crf",
        "18",
        output_abs
      ])

    :ok
  end

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get(_map, _key, default), do: default
end

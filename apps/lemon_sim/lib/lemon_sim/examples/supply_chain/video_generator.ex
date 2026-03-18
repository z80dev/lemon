defmodule LemonSim.Examples.SupplyChain.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.SupplyChain.{FrameRenderer, GameLog}

  @default_fps 2
  @default_hold_frames 1
  @default_width 1920
  @default_height 1080

  @doc """
  Generates a gameplay video from a supply chain JSONL log file.

  Returns `{:ok, video_path}` or `{:error, reason}`.

  ## Options

    * `:output` - Output video path (default: derived from log_path)
    * `:fps` - Frames per second (default: #{@default_fps})
    * `:hold_frames` - Base frame duplication for pacing (default: #{@default_hold_frames})
    * `:width` - Frame width in pixels (default: #{@default_width})
    * `:height` - Frame height in pixels (default: #{@default_height})
    * `:keep_frames` - Keep intermediate SVG/PNG files (default: false)

  """
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
        entries = GameLog.read_log(log_path)
        total = length(entries)

        IO.puts("Read #{total} log entries from #{log_path}")

        frame_index = render_all_frames(entries, tmp_dir, render_opts, hold_frames, total)

        IO.puts("Converting #{frame_index} frames to PNG...")
        :ok = convert_svgs_to_pngs(tmp_dir, frame_index, width, height)

        IO.puts("Encoding video...")
        :ok = encode_video(tmp_dir, frame_index, fps, output)

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp validate_input(log_path) do
    if File.exists?(log_path), do: :ok, else: {:error, {:file_not_found, log_path}}
  end

  defp derive_output_path(log_path) do
    log_path |> Path.rootname() |> Kernel.<>(".mp4")
  end

  defp create_temp_dir do
    dir_name = "lemon_supply_chain_replay_#{System.system_time(:millisecond)}"
    dir = Path.join(System.tmp_dir!(), dir_name)
    File.mkdir_p!(dir)
    dir
  end

  defp render_all_frames(entries, tmp_dir, render_opts, base_hold, total) do
    {final_index, _} =
      Enum.reduce(entries, {1, 1}, fn entry, {frame_index, entry_num} ->
        IO.puts("Rendering frame #{entry_num}/#{total}...")
        hold_count = hold_count_for(entry, base_hold)

        svg = FrameRenderer.render_frame(entry, render_opts)

        new_index =
          Enum.reduce(1..hold_count, frame_index, fn _i, idx ->
            path = frame_path(tmp_dir, idx, "svg")
            File.write!(path, svg)
            idx + 1
          end)

        {new_index, entry_num + 1}
      end)

    final_index - 1
  end

  defp hold_count_for(entry, base_hold) do
    type = get(entry, "type", "step")
    events = get(entry, "events", [])

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 5
        has_event?(events, "demand_realized") -> 3
        has_event?(events, "round_advanced") -> 2
        has_event?(events, "order_fulfilled") -> 2
        true -> 1
      end

    base_hold * multiplier
  end

  defp has_event?(events, kind) when is_list(events) do
    Enum.any?(events, fn
      %{"kind" => k} -> k == kind
      %{kind: k} -> to_string(k) == kind
      _ -> false
    end)
  end

  defp has_event?(_, _), do: false

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

  defp encode_video(tmp_dir, _frame_count, fps, output) do
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

  defp get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          ArgumentError -> default
        end

      val ->
        val
    end
  end

  defp get(_, _, default), do: default
end

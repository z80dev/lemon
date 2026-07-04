defmodule LemonSim.Examples.Rendering.VideoGenerator do
  @moduledoc """
  Shared frame-to-video orchestration for scenario replay videos.

  Each scenario's `VideoGenerator` module is a thin wrapper that builds a
  `Config` and delegates here. The pipeline is: read log entries, build a
  frame sequence (entry + hold-frame count), render each frame to SVG via the
  scenario's frame renderer, convert to PNG with `rsvg-convert`, and encode
  with `ffmpeg`.

  ## Options accepted by `generate/3`

    * `:output` - output video path (default: log path with `.mp4` extension)
    * `:fps` - frames per second (default: 2)
    * `:hold_frames` - base hold count per entry (default: 1)
    * `:width` / `:height` - frame dimensions (default: 1920x1080)
    * `:keep_frames` - keep the temp frame directory for debugging
  """

  defmodule Config do
    @moduledoc """
    Per-scenario configuration for the shared video pipeline.

    Required: `:frame_renderer` (module with `render_frame/2`), `:dir_name`
    (temp-dir prefix), `:read_entries` (log path -> entries), `:build_frames`
    (entries + opts -> frame maps). Optional `:init_render_state` and
    `:render_opts` thread scenario state (e.g. werewolf's elimination log)
    through the render loop.
    """

    @enforce_keys [:frame_renderer, :dir_name, :read_entries, :build_frames]
    defstruct [
      :frame_renderer,
      :dir_name,
      :read_entries,
      :build_frames,
      read_message: "Read",
      read_subject: "log entries",
      init_render_state: nil,
      render_opts: nil
    ]

    @type t :: %__MODULE__{
            frame_renderer: module(),
            dir_name: String.t(),
            read_entries: (String.t() -> [map()]),
            build_frames: ([map()], keyword() -> [map()]),
            read_message: String.t(),
            read_subject: String.t(),
            init_render_state: ([map()] -> term()) | nil,
            render_opts: (map(), term(), keyword() -> {keyword(), term()}) | nil
          }
  end

  @default_fps 2
  @default_hold_frames 1
  @default_width 1920
  @default_height 1080

  @spec generate(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(%Config{} = config, log_path, opts \\ []) do
    with :ok <- check_dependencies(),
         :ok <- validate_input(log_path) do
      output = Keyword.get(opts, :output, derive_output_path(log_path))
      fps = Keyword.get(opts, :fps, @default_fps)
      hold_frames = Keyword.get(opts, :hold_frames, @default_hold_frames)
      width = Keyword.get(opts, :width, @default_width)
      height = Keyword.get(opts, :height, @default_height)
      keep_frames = Keyword.get(opts, :keep_frames, false)

      render_opts = [width: width, height: height]
      tmp_dir = create_temp_dir(config)

      try do
        entries = config.read_entries.(log_path)
        frames = build_frames(config, entries, fps: fps, hold_frames: hold_frames)
        total = length(frames)

        IO.puts("#{config.read_message} #{total} #{config.read_subject} from #{log_path}")

        frame_index = render_all_frames(frames, tmp_dir, render_opts, total, config)

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

  @spec build_frames(Config.t(), [map()], keyword()) :: [map()]
  def build_frames(%Config{} = config, entries, opts) do
    config.build_frames.(entries, opts)
  end

  @spec default_frames([map()], keyword(), (map(), pos_integer() -> pos_integer())) :: [map()]
  def default_frames(entries, opts, hold_count_fun) do
    base_hold = Keyword.fetch!(opts, :hold_frames)

    Enum.map(entries, fn entry ->
      %{entry: entry, hold_frames: hold_count_fun.(entry, base_hold)}
    end)
  end

  defp validate_input(log_path) do
    if File.exists?(log_path), do: :ok, else: {:error, {:file_not_found, log_path}}
  end

  defp derive_output_path(log_path) do
    log_path |> Path.rootname() |> Kernel.<>(".mp4")
  end

  defp create_temp_dir(%Config{dir_name: dir_name}) do
    dir = Path.join(System.tmp_dir!(), "#{dir_name}_#{System.system_time(:millisecond)}")
    File.mkdir_p!(dir)
    dir
  end

  defp render_all_frames(frames, tmp_dir, render_opts, total, config) do
    initial_state = init_render_state(config, frames)

    {final_index, _, _} =
      Enum.reduce(frames, {1, 1, initial_state}, fn %{entry: entry, hold_frames: hold_count},
                                                    {frame_index, entry_num, state} ->
        IO.puts("Rendering frame #{entry_num}/#{total}...")
        {frame_opts, state} = render_opts(config, entry, state, render_opts)

        svg = config.frame_renderer.render_frame(entry, frame_opts)

        new_index =
          Enum.reduce(1..hold_count, frame_index, fn _i, idx ->
            path = frame_path(tmp_dir, idx, "svg")
            File.write!(path, svg)
            idx + 1
          end)

        {new_index, entry_num + 1, state}
      end)

    final_index - 1
  end

  defp frame_path(tmp_dir, index, extension) do
    filename = "frame_#{String.pad_leading(Integer.to_string(index), 4, "0")}.#{extension}"
    Path.join(tmp_dir, filename)
  end

  defp init_render_state(%Config{init_render_state: nil}, _frames), do: nil
  defp init_render_state(%Config{init_render_state: fun}, frames), do: fun.(frames)

  defp render_opts(%Config{render_opts: nil}, _entry, state, opts), do: {opts, state}
  defp render_opts(%Config{render_opts: fun}, entry, state, opts), do: fun.(entry, state, opts)

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
end

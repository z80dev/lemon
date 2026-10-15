defmodule LemonCli.LogsCommand do
  @moduledoc "Read-only runtime log tail with a bounded, redacted launcher-file fallback."

  alias LemonCli.RunsCommand

  @max_bytes 1_048_576
  @levels ~w(debug info notice warning error critical alert emergency)

  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [lines: :integer, level: :string, follow: :boolean, json: :boolean],
        aliases: [n: :lines]
      )

    count = opts[:lines] || 50

    cond do
      rest != [] or invalid != [] or count not in 1..1_000 -> usage()
      opts[:level] && opts[:level] not in ~w(info warning error) -> usage()
      true -> start(Keyword.put(opts, :lines, count))
    end
  end

  defp usage do
    IO.puts(
      :stderr,
      "Use lemon logs [-n 1..1000] [--level info|warning|error] [--follow] [--json]."
    )

    2
  end

  defp start(opts) do
    case runtime_logs(opts, opts[:lines]) do
      {:ok, entries} ->
        emit(entries, "runtime logs.tail", opts)
        if opts[:follow], do: follow_runtime(opts, cursor(entries)), else: 0

      {:error, {:control_plane_unavailable, _}} ->
        start_file(opts)

      {:error, reason} ->
        RunsCommand.failure(reason, opts[:json])
    end
  end

  defp runtime_logs(opts, limit) do
    params = %{"limit" => limit}
    params = if opts[:level], do: Map.put(params, "level", opts[:level]), else: params

    case RunsCommand.request("logs.tail", params) do
      {:ok, %{"logs" => entries}} when is_list(entries) -> {:ok, entries}
      {:ok, _} -> {:error, :invalid_response}
      error -> error
    end
  end

  defp follow_runtime(opts, cursor) do
    receive do
      :lemon_logs_stop -> 0
    after
      2_000 -> poll_runtime(opts, cursor)
    end
  end

  defp poll_runtime(opts, cursor) do
    case runtime_logs(opts, 1_000) do
      {:ok, entries} ->
        {fresh, next} = advance(entries, cursor)
        emit(fresh, "runtime logs.tail", opts, false)
        follow_runtime(opts, next)

      {:error, reason} ->
        RunsCommand.failure(reason, opts[:json])
    end
  end

  @doc false
  def advance(entries, {timestamp, seen}) do
    fresh =
      Enum.filter(entries, fn entry ->
        entry["timestampMs"] > timestamp or
          (entry["timestampMs"] == timestamp and not MapSet.member?(seen, entry))
      end)

    {fresh, cursor(entries ++ MapSet.to_list(seen), timestamp)}
  end

  defp cursor(entries, minimum \\ 0) do
    timestamp =
      Enum.reduce(entries, minimum, fn entry, acc -> max(entry["timestampMs"] || 0, acc) end)

    {timestamp, entries |> Enum.filter(&(&1["timestampMs"] == timestamp)) |> MapSet.new()}
  end

  defp start_file(opts) do
    with {:ok, path} <- log_path(),
         {:ok, lines} <- tail_file(path, opts[:lines]) do
      source =
        if System.get_env("LEMON_CLI_LAUNCHER") == "release" do
          "launcher release log"
        else
          "launcher lemon-#{System.get_env("LEMON_CONTROL_PLANE_PORT") || "4040"}.log"
        end

      emit(file_entries(lines, opts), source, opts)
      if opts[:follow], do: follow_file(path, lines, source, opts), else: 0
    else
      _ -> file_failure(opts)
    end
  end

  defp follow_file(path, previous, source, opts) do
    receive do
      :lemon_logs_stop -> 0
    after
      2_000 ->
        case tail_file(path, 1_000) do
          {:ok, lines} ->
            emit(file_entries(new_lines(previous, lines), opts), source, opts, false)
            follow_file(path, lines, source, opts)

          _ ->
            file_failure(opts)
        end
    end
  end

  defp new_lines(previous, lines) do
    overlap =
      Enum.find(min(length(previous), length(lines))..0//-1, fn count ->
        Enum.take(previous, -count) == Enum.take(lines, count)
      end)

    Enum.drop(lines, overlap)
  end

  defp file_failure(opts) do
    message =
      "Runtime not running or unreachable; launcher log is unavailable. Start it with `lemon daemon`."

    if opts[:json],
      do: IO.puts(:stderr, Jason.encode!(%{error: %{message: message}})),
      else: IO.puts(:stderr, message)

    1
  end

  defp log_path do
    case System.get_env("LEMON_RUNTIME_LOG_FILE") do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> default_log_path()
    end
  end

  defp default_log_path do
    if System.get_env("LEMON_CLI_LAUNCHER") == "release" do
      directory = System.get_env("LEMON_RUNTIME_LOG_DIR")
      release_log(directory)
    else
      port = System.get_env("LEMON_CONTROL_PLANE_PORT") || "4040"
      {:ok, LemonCore.Paths.home_path(["run", "lemon-#{port}.log"])}
    end
  end

  defp release_log(nil), do: {:error, :no_log_directory}

  defp release_log(directory) do
    with {:ok, names} <- File.ls(directory) do
      candidates =
        names
        |> Enum.filter(&Regex.match?(~r/\Aerlang\.log\.\d+\z/, &1))
        |> Enum.map(&Path.join(directory, &1))
        |> Enum.flat_map(fn path ->
          case File.stat(path, time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} -> [{mtime, path}]
            _ -> []
          end
        end)

      case Enum.max_by(candidates, &elem(&1, 0), fn -> nil end) do
        nil -> {:error, :no_log_file}
        {_, path} -> {:ok, path}
      end
    end
  end

  @doc false
  def tail_file(path, count) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          read_tail(file, count)
        after
          :file.close(file)
        end

      error ->
        error
    end
  end

  defp read_tail(file, count) do
    with {:ok, size} <- :file.position(file, :eof),
         start = max(size - @max_bytes, 0),
         {:ok, _} <- :file.position(file, start) do
      data = if size == 0, do: {:ok, ""}, else: :file.read(file, size - start)

      case data do
        {:ok, bytes} ->
          parts = :binary.split(bytes, "\n", [:global])
          parts = if start > 0, do: Enum.drop(parts, 1), else: parts
          parts = if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
          {:ok, parts |> Enum.take(-count) |> Enum.map(&safe_line/1)}

        error ->
          error
      end
    end
  end

  defp safe_line(line) do
    line
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
    |> LemonCore.Redact.text()
  end

  defp file_entries(lines, opts) do
    lines
    |> Enum.filter(fn line -> is_nil(opts[:level]) or above_level?(line, opts[:level]) end)
    |> Enum.map(&%{"message" => &1})
  end

  defp above_level?(line, minimum) do
    case Regex.run(~r/\[(debug|info|notice|warning|warn|error|critical|alert|emergency)\]/i, line) do
      [_, level] ->
        level = if String.downcase(level) == "warn", do: "warning", else: String.downcase(level)
        Enum.find_index(@levels, &(&1 == level)) >= Enum.find_index(@levels, &(&1 == minimum))

      _ ->
        false
    end
  end

  defp emit(entries, source, opts, header? \\ true) do
    if opts[:json] do
      IO.puts(Jason.encode!(%{source: source, logs: entries}))
    else
      if header?, do: IO.puts("Logs: #{source} (credential-redacted)")

      Enum.each(entries, fn entry ->
        prefix =
          Enum.reject([entry["timestampMs"], entry["level"], entry["module"]], &is_nil/1)
          |> Enum.join(" ")

        IO.puts(clean(prefix <> " " <> (entry["message"] || "")))
      end)
    end
  end

  defp clean(text),
    do: text |> LemonCore.Redact.text() |> String.replace(~r/[\x00-\x08\x0b-\x1f\x7f-\x9f]/u, " ")
end

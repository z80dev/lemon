defmodule CodingAgent.Tools.LspFormatter do
  @moduledoc """
  Auto-formatter abstraction supporting multiple languages.

  Detects the appropriate formatter (mix format, prettier, black, rustfmt, gofmt)
  based on file extension and runs it if the executable is available.

  Formatters never open the workspace file. Every supported formatter runs as
  a filter: Lemon stages the bytes it wrote into a private `0700` directory
  (`CodingAgent.Tools.CheckerStaging`), the formatter reads them on stdin and
  writes stdout into that directory, and Lemon reads the result back bounded.
  The workspace path is passed only as a hint for project configuration lookup
  (`mix format --stdin-filename`, `prettier --stdin-filepath`,
  `black --stdin-filename`; `rustfmt` looks up its configuration from its
  working directory, the file's directory). Those configuration reads are
  the formatter's own and outside Lemon's confined I/O; the formatter is
  never given a path it writes in the workspace.

  `after_write/5` commits a changed result in place through
  `CodingAgent.Tools.FileValidation.write_regular_file/3`, bound to the file
  Lemon just wrote: the file is located below the same mutation boundary as
  the write (a symlink anywhere below it is refused) and must still hold
  exactly the bytes Lemon wrote, both before the formatter runs and right
  before the commit; otherwise the formatter output is discarded with an error.
  """

  alias CodingAgent.Tools.Bash.CommandPolicy
  alias CodingAgent.Tools.{CheckerRunner, CheckerStaging, FileValidation}

  @default_timeout_ms 15_000

  # Formatter input and output are bounded.
  @max_bytes 8 * 1024 * 1024

  # Argument placeholders: `:path` is the workspace path, `:relative_path` the
  # path relative to the formatter's working directory (mix matches
  # `.formatter.exs` subdirectories against it). `cwd: :file_dir` runs the
  # formatter in the file's directory instead of the tool's.
  @formatters %{
    elixir: %{
      command: "mix",
      args: ["format", "--stdin-filename", :relative_path, "-"],
      # Mix prints compile progress for formatter plugins on stdout.
      env: [{"MIX_QUIET", "1"}],
      extensions: [".ex", ".exs", ".heex"]
    },
    javascript: %{
      command: "prettier",
      args: ["--stdin-filepath", :path],
      extensions: [".js", ".ts", ".jsx", ".tsx", ".json", ".md"]
    },
    python: %{
      command: "black",
      args: ["--quiet", "--stdin-filename", :path, "-"],
      extensions: [".py"]
    },
    rust: %{
      command: "rustfmt",
      args: ["--emit", "stdout"],
      cwd: :file_dir,
      extensions: [".rs"]
    },
    go: %{
      command: "gofmt",
      args: [],
      extensions: [".go"]
    }
  }

  @doc """
  Return the map of supported language formatters and their configuration.
  """
  @spec list_formatters() :: map()
  def list_formatters, do: @formatters

  @doc """
  Check whether a file path has a known formatter based on its extension.
  """
  @spec formatable?(String.t()) :: boolean()
  def formatable?(path) when is_binary(path) do
    ext = normalize_extension(path)
    Enum.any?(@formatters, fn {_name, cfg} -> ext in cfg.extensions end)
  end

  def formatable?(_), do: false

  @doc false
  # Project formatters run project code (plugins, config files), which no
  # command list can inspect: under `allowed_commands`/`blocked_commands` an
  # explicit `format: true` is refused and a configured default is skipped.
  def option(params, opts) do
    explicit? = Map.has_key?(params, "format")

    case Map.get(params, "format", Keyword.get(opts, :format, false)) do
      true ->
        cond do
          not CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)) -> {:ok, true}
          explicit? -> {:error, CommandPolicy.unavailable("format")}
          true -> {:ok, false}
        end

      false ->
        {:ok, false}

      _ ->
        {:error, "format must be a boolean"}
    end
  end

  @doc false
  # Formats the file a mutation tool just wrote with `written` and returns
  # `{final_bytes, formatted?, error}`: the bytes now in the file as far as
  # Lemon wrote them. `:format_content_fun` (same contract as
  # `format_content/3`) is a test seam.
  def after_write(_path, written, false, _cwd, _opts), do: {written, false, nil}

  def after_write(path, written, true, cwd, opts) do
    tool_policy = Keyword.get(opts, :tool_policy)

    if CommandPolicy.restricted?(tool_policy) do
      {written, false, nil}
    else
      formatter = Keyword.get(opts, :format_content_fun, &format_content/3)
      timeout_ms = Keyword.get(opts, :format_timeout_ms, 5_000)
      io_opts = Keyword.put(opts, :mutation_root, cwd)

      format_opts =
        [cwd: cwd, timeout_ms: timeout_ms, tool_policy: tool_policy] ++
          Keyword.take(opts, [:signal, :session_id, :session_pid, :repo_local_tools])

      with {:ok, identity} <- written_identity(path, written, io_opts),
           {:ok, formatted} <- formatter.(path, written, format_opts) do
        if formatted == written do
          {written, false, nil}
        else
          case commit(path, identity, written, formatted) do
            :ok -> {formatted, true, nil}
            {:error, reason} -> {written, false, reason}
          end
        end
      else
        {:error, reason} -> {written, false, describe(reason, path)}
      end
    end
  end

  @doc """
  Format `content` as the file `path` with the language's formatter.

  `path` names the file only for project configuration lookup; the formatter
  reads `content` from a private staging file and its output is read back
  from there (at most #{@max_bytes} bytes). Returns `{:ok, formatted}`
  (`content` itself when no formatter applies or its executable is missing)
  or `{:error, reason}`.
  """
  @spec format_content(String.t(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def format_content(path, content, opts \\ [])

  def format_content(path, content, opts) when is_binary(path) and is_binary(content) do
    cwd = opts[:cwd] || Path.dirname(path)

    with :ok <- check_policy(opts),
         {:ok, formatter} <- formatter_for_path(path),
         :ok <- check_size(content, "input"),
         {:ok, executable} <- resolve_executable(formatter.command, cwd, opts),
         {:ok, timeout_ms} <- resolve_timeout(opts) do
      run_formatter(formatter, executable, path, content, cwd, timeout_ms, opts)
    else
      {:skip, :not_formatable} -> {:ok, content}
      {:skip, :missing_executable} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def format_content(_path, _content, _opts), do: {:error, "path and content must be strings"}

  # The file must still be the one Lemon wrote, holding exactly what it wrote.
  defp written_identity(path, written, io_opts) do
    with {:ok, identity} <- FileValidation.regular_file_identity(path, io_opts),
         :ok <- still_written(path, identity, written) do
      {:ok, identity}
    end
  end

  defp commit(path, identity, written, formatted) do
    with :ok <- still_written(path, identity, written) do
      FileValidation.write_regular_file(path, identity, formatted)
    end
  end

  # One byte past `written` tells a grown file apart without a size error.
  defp still_written(path, identity, written) do
    case FileValidation.read_regular_file(path, identity,
           max_bytes: byte_size(written) + 1,
           prefix: true
         ) do
      {:ok, ^written} ->
        :ok

      {:ok, _other} ->
        {:error, "#{path} changed after it was written; formatter output was not applied"}

      {:error, _} = error ->
        error
    end
  end

  defp run_formatter(formatter, executable, path, content, cwd, timeout_ms, opts) do
    CheckerStaging.with_dir(fn stage ->
      with :ok <- staged(CheckerStaging.write(stage, "input", content)) do
        args =
          ["-c", filter_script(formatter), "lemon-format"] ++
            [
              CheckerStaging.path(stage, "input"),
              CheckerStaging.path(stage, "output"),
              executable
            ] ++
            formatter_args(formatter, path, cwd)

        run_cwd = if Map.get(formatter, :cwd) == :file_dir, do: Path.dirname(path), else: cwd

        case CheckerRunner.run("/bin/sh", args, run_cwd, timeout_ms, 8_192, opts) do
          {:ok, %{exit_code: 0, timed_out: false, cancelled: false}} ->
            read_output(stage, content)

          {:ok, result} ->
            formatter_result(result)

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      end
    end)
  end

  # stdin and stdout are the staged files; stderr stays the run's output.
  defp filter_script(formatter) do
    exports =
      formatter
      |> Map.get(:env, [])
      |> Enum.map_join(fn {name, value} -> "export #{name}=#{value}; " end)

    exports <> ~S|in=$1; out=$2; shift 2; exec "$@" <"$in" >"$out"|
  end

  defp formatter_args(formatter, path, cwd) do
    Enum.map(formatter.args, fn
      :path -> path
      :relative_path -> Path.relative_to(path, cwd)
      arg -> arg
    end)
  end

  defp read_output(stage, content) do
    case CheckerStaging.read(stage, "output", @max_bytes) do
      {:ok, ""} ->
        if String.trim(content) == "",
          do: {:ok, ""},
          else: {:error, "formatter produced no output"}

      {:ok, formatted} ->
        {:ok, formatted}

      {:error, :too_large} ->
        {:error, "formatter output exceeds #{@max_bytes} bytes"}

      {:error, reason} ->
        {:error, "cannot read formatter output (#{reason})"}
    end
  end

  defp describe(reason, _path) when is_binary(reason), do: reason

  defp describe(reason, path) when is_atom(reason),
    do: FileValidation.format_file_error(reason, path, "file")

  defp describe(reason, _path), do: inspect(reason)

  defp staged(:ok), do: :ok
  defp staged({:error, reason}), do: {:error, "cannot stage formatter input (#{reason})"}

  defp check_size(content, label) do
    if byte_size(content) <= @max_bytes,
      do: :ok,
      else: {:error, "formatter #{label} exceeds #{@max_bytes} bytes"}
  end

  defp check_policy(opts) do
    if CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)),
      do: {:error, CommandPolicy.unavailable("format")},
      else: :ok
  end

  defp formatter_result(%{timed_out: true}), do: {:error, "formatter timed out"}
  defp formatter_result(%{cancelled: true}), do: {:error, "formatter cancelled"}

  defp formatter_result(%{output: output, exit_code: status}),
    do: {:error, "formatter exited with status #{status}: #{String.trim(output)}"}

  defp formatter_for_path(path) do
    ext = normalize_extension(path)

    case Enum.find(@formatters, fn {_name, cfg} -> ext in cfg.extensions end) do
      nil -> {:skip, :not_formatable}
      {_name, formatter} -> {:ok, formatter}
    end
  end

  defp resolve_executable(command, cwd, opts) do
    case CheckerRunner.resolve(command, [cwd], opts) do
      {:ok, executable} ->
        {:ok, executable}

      :missing ->
        {:skip, :missing_executable}

      :repo_local ->
        {:error,
         "refused repo-local executable: #{command} (runtime.tools.edit.repo_local_tools)"}
    end
  end

  defp resolve_timeout(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    cond do
      is_integer(timeout_ms) and timeout_ms > 0 -> {:ok, timeout_ms}
      true -> {:error, "timeout must be a positive integer"}
    end
  end

  defp normalize_extension(path) do
    path
    |> Path.extname()
    |> String.downcase()
  end
end

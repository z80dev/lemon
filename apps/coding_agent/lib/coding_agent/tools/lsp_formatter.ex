defmodule CodingAgent.Tools.LspFormatter do
  @moduledoc """
  Auto-formatter abstraction supporting multiple languages.

  Detects the appropriate formatter (mix format, prettier, black, rustfmt, gofmt)
  based on file extension and runs it if the executable is available.
  """

  alias CodingAgent.Tools.Bash.CommandPolicy
  alias CodingAgent.Tools.CheckerRunner

  @default_timeout_ms 15_000

  @formatters %{
    elixir: %{
      command: "mix",
      args: ["format"],
      extensions: [".ex", ".exs", ".heex"]
    },
    javascript: %{
      command: "prettier",
      args: ["--write"],
      extensions: [".js", ".ts", ".jsx", ".tsx", ".json", ".md"]
    },
    python: %{
      command: "black",
      args: [],
      extensions: [".py"]
    },
    rust: %{
      command: "rustfmt",
      args: [],
      extensions: [".rs"]
    },
    go: %{
      command: "gofmt",
      args: ["-w"],
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
  def after_write(_path, false, _cwd, _opts), do: {false, nil}

  def after_write(path, true, cwd, opts) do
    tool_policy = Keyword.get(opts, :tool_policy)

    if CommandPolicy.restricted?(tool_policy) do
      {false, nil}
    else
      formatter = Keyword.get(opts, :format_file_fun, &format_file/2)
      timeout_ms = Keyword.get(opts, :format_timeout_ms, 5_000)

      format_opts =
        [cwd: cwd, timeout_ms: timeout_ms, tool_policy: tool_policy] ++
          Keyword.take(opts, [:signal, :session_id, :session_pid, :repo_local_tools])

      case formatter.(path, format_opts) do
        {:ok, :formatted} -> {true, nil}
        {:ok, :unchanged} -> {false, nil}
        {:error, reason} -> {false, to_string(reason)}
      end
    end
  end

  @doc """
  Format a file using the appropriate language formatter.

  Returns `{:ok, :formatted}` when the file was modified, `{:ok, :unchanged}`
  when no changes were needed or no formatter is available, or `{:error, reason}`.
  """
  @spec format_file(String.t(), keyword()) :: {:ok, :formatted | :unchanged} | {:error, term()}
  def format_file(path, opts \\ [])

  def format_file(path, opts) when is_binary(path) do
    cwd = opts[:cwd] || Path.dirname(path)

    with :ok <- check_policy(opts),
         {:ok, formatter} <- formatter_for_path(path),
         {:ok, _} <- ensure_file_exists(path),
         {:ok, executable} <- resolve_executable(formatter.command, cwd, opts),
         {:ok, timeout_ms} <- resolve_timeout(opts) do
      before = File.read(path)
      args = formatter.args ++ [path]

      case CheckerRunner.run(executable, args, cwd, timeout_ms, 8_192, opts) do
        {:ok, result} -> formatter_result(result, before, path)
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:skip, :not_formatable} -> {:ok, :unchanged}
      {:skip, :missing_executable} -> {:ok, :unchanged}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  def format_file(_path, _opts), do: {:error, "path must be a string"}

  defp check_policy(opts) do
    if CommandPolicy.restricted?(Keyword.get(opts, :tool_policy)),
      do: {:error, CommandPolicy.unavailable("format")},
      else: :ok
  end

  defp formatter_result(%{timed_out: true}, _before, _path),
    do: {:error, "formatter timed out"}

  defp formatter_result(%{cancelled: true}, _before, _path),
    do: {:error, "formatter cancelled"}

  defp formatter_result(%{exit_code: 0}, before, path) do
    after_read = File.read(path)

    case {before, after_read} do
      {{:ok, before_content}, {:ok, after_content}} when before_content != after_content ->
        {:ok, :formatted}

      _ ->
        {:ok, :unchanged}
    end
  end

  defp formatter_result(%{output: output, exit_code: status}, _before, _path),
    do: {:error, "formatter exited with status #{status}: #{String.trim(output)}"}

  defp formatter_for_path(path) do
    ext = normalize_extension(path)

    case Enum.find(@formatters, fn {_name, cfg} -> ext in cfg.extensions end) do
      nil -> {:skip, :not_formatable}
      {_name, formatter} -> {:ok, formatter}
    end
  end

  defp ensure_file_exists(path) do
    if File.exists?(path), do: {:ok, path}, else: {:error, "file not found: #{path}"}
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

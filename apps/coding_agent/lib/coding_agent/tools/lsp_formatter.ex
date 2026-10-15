defmodule CodingAgent.Tools.LspFormatter do
  @moduledoc """
  Auto-formatter abstraction supporting multiple languages.

  Detects the appropriate formatter (mix format, prettier, black, rustfmt, gofmt)
  based on file extension and runs it if the executable is available.
  """

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
  def option(params, opts) do
    case Map.get(params, "format", Keyword.get(opts, :format, false)) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "format must be a boolean"}
    end
  end

  @doc false
  def after_write(_path, false, _cwd, _opts), do: {false, nil}

  def after_write(path, true, cwd, opts) do
    formatter = Keyword.get(opts, :format_file_fun, &format_file/2)
    timeout_ms = Keyword.get(opts, :format_timeout_ms, 5_000)

    case formatter.(path, cwd: cwd, timeout_ms: timeout_ms) do
      {:ok, :formatted} -> {true, nil}
      {:ok, :unchanged} -> {false, nil}
      {:error, reason} -> {false, to_string(reason)}
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
    with {:ok, formatter} <- formatter_for_path(path),
         {:ok, _} <- ensure_file_exists(path),
         {:ok, executable} <- ensure_executable(formatter.command),
         {:ok, timeout_ms} <- resolve_timeout(opts) do
      before = File.read(path)
      args = formatter.args ++ [path]

      command =
        Enum.map_join([executable | args], " ", fn arg ->
          "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"
        end)

      result =
        CodingAgent.BashExecutor.execute(command, opts[:cwd],
          timeout: timeout_ms,
          max_bytes: 8_192
        )

      case result do
        {:ok, result} ->
          if result.full_output_path, do: File.rm(result.full_output_path)
          formatter_result(result, before, path)

        {:error, reason} ->
          {:error, inspect(reason)}
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

  defp formatter_result(%{timed_out: true}, _before, _path),
    do: {:error, "formatter timed out"}

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

  defp ensure_executable(command) do
    case System.find_executable(command) do
      nil -> {:skip, :missing_executable}
      executable -> {:ok, executable}
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

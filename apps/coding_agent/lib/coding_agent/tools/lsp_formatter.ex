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

      cmd_opts =
        [stderr_to_stdout: true, timeout: timeout_ms]
        |> maybe_put_cd(opts[:cwd])

      case System.cmd(executable, args, cmd_opts) do
        {_output, 0} ->
          after_read = File.read(path)

          case {before, after_read} do
            {{:ok, before_content}, {:ok, after_content}} when before_content != after_content ->
              {:ok, :formatted}

            _ ->
              {:ok, :unchanged}
          end

        {output, status} ->
          {:error, "formatter exited with status #{status}: #{String.trim(output)}"}
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

  defp maybe_put_cd(cmd_opts, cwd) when is_binary(cwd), do: Keyword.put(cmd_opts, :cd, cwd)
  defp maybe_put_cd(cmd_opts, _cwd), do: cmd_opts

  defp normalize_extension(path) do
    path
    |> Path.extname()
    |> String.downcase()
  end
end

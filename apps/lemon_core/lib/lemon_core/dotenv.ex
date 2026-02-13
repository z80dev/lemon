defmodule LemonCore.Dotenv do
  @moduledoc """
  Minimal `.env` loader for Lemon runtime processes.

  The loader reads `<dir>/.env` and exports variables into `System` environment.
  Existing environment variables are preserved by default.
  """

  require Logger

  @key_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @doc """
  Load `<dir>/.env` into process environment.

  If `dir` is nil or empty, the current process directory is used.
  Returns `:ok` when the file is absent or loaded successfully.
  """
  @spec load(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def load(dir \\ nil, opts \\ []) do
    path = path_for(dir)
    override? = Keyword.get(opts, :override, false)

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split(~r/\r?\n/)
        |> Enum.each(fn line ->
          case parse_line(line) do
            {:ok, key, value} ->
              if override? or is_nil(System.get_env(key)) do
                System.put_env(key, value)
              end

            :skip ->
              :ok
          end
        end)

        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Same as `load/2`, but logs warnings and always returns `:ok`.
  """
  @spec load_and_log(String.t() | nil, keyword()) :: :ok
  def load_and_log(dir \\ nil, opts \\ []) do
    case load(dir, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load .env at #{path_for(dir)}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Resolve the `.env` path for a directory.
  """
  @spec path_for(String.t() | nil) :: String.t()
  def path_for(nil), do: Path.join(File.cwd!(), ".env")
  def path_for(""), do: Path.join(File.cwd!(), ".env")
  def path_for(dir), do: Path.join(Path.expand(dir), ".env")

  defp parse_line(line) when is_binary(line) do
    line = String.trim(line)

    cond do
      line == "" ->
        :skip

      String.starts_with?(line, "#") ->
        :skip

      true ->
        line
        |> strip_export_prefix()
        |> parse_assignment()
    end
  end

  defp strip_export_prefix(line) do
    if String.starts_with?(line, "export ") do
      line
      |> String.replace_prefix("export ", "")
      |> String.trim_leading()
    else
      line
    end
  end

  defp parse_assignment(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        if Regex.match?(@key_pattern, key) do
          {:ok, key, parse_value(raw_value)}
        else
          :skip
        end

      _ ->
        :skip
    end
  end

  defp parse_value(raw_value) do
    raw_value = String.trim_leading(raw_value)

    cond do
      raw_value == "" ->
        ""

      String.starts_with?(raw_value, "\"") ->
        parse_double_quoted(raw_value)

      String.starts_with?(raw_value, "'") ->
        parse_single_quoted(raw_value)

      true ->
        raw_value
        |> strip_inline_comment()
        |> String.trim()
    end
  end

  defp parse_single_quoted(raw_value) do
    case Regex.run(~r/^'([^']*)'(?:\s+#.*)?\s*$/, raw_value, capture: :all_but_first) do
      [value] ->
        value

      _ ->
        raw_value
        |> strip_inline_comment()
        |> String.trim()
    end
  end

  defp parse_double_quoted(raw_value) do
    case Regex.run(~r/^"((?:\\.|[^"])*)"(?:\s+#.*)?\s*$/, raw_value, capture: :all_but_first) do
      [value] ->
        unescape_double_quoted(value)

      _ ->
        raw_value
        |> strip_inline_comment()
        |> String.trim()
    end
  end

  defp strip_inline_comment(value) do
    Regex.replace(~r/\s+#.*$/, value, "")
  end

  defp unescape_double_quoted(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end
end

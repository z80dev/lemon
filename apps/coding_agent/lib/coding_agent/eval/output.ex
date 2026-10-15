defmodule CodingAgent.Eval.Output do
  @moduledoc """
  Bounded accumulator for `eval` cell output, matching the `bash` tool's
  output contract: output is sanitized like shell output, decoded as UTF-8
  across chunks, kept in memory up to twice the byte cap and spilled to a
  private (0600) temp file beyond that. `finalize/1` returns the tail within
  the byte/line caps plus the full-output path whenever it truncated.
  """

  alias CodingAgent.BashExecutor

  @default_max_bytes 50_000
  @max_lines 2000

  defstruct buffer: [],
            utf8_tail: "",
            total_bytes: 0,
            newline_terminated: true,
            file: nil,
            path: nil,
            max_bytes: @default_max_bytes

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []),
    do: %__MODULE__{max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)}

  @doc "Appends raw bytes; returns the accumulator and the sanitized text added."
  @spec append(t(), binary()) :: {t(), String.t()}
  def append(%__MODULE__{} = acc, data) when is_binary(data) do
    {decoded, tail} = decode_utf8(acc.utf8_tail <> data, [])
    text = BashExecutor.sanitize_output(decoded)
    {store(%{acc | utf8_tail: tail}, text), text}
  end

  @doc """
  Appends a display value or error report on its own line, sanitizing it with
  the same rules as streamed shell output.
  """
  @spec append_block(t(), String.t()) :: t()
  def append_block(%__MODULE__{} = acc, text) when is_binary(text) do
    acc = flush_tail(acc)
    acc = if acc.newline_terminated, do: acc, else: store(acc, "\n")
    store(acc, BashExecutor.sanitize_output(text))
  end

  @doc "Whether nothing has been recorded yet."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{total_bytes: 0, utf8_tail: ""}), do: true
  def empty?(%__MODULE__{}), do: false

  @spec finalize(t()) :: %{
          output: String.t(),
          truncated: boolean(),
          full_output_path: String.t() | nil
        }
  def finalize(%__MODULE__{} = acc) do
    acc = flush_tail(acc)
    if acc.file, do: File.close(acc.file)

    full =
      if acc.path,
        do: read_tail(acc.path, acc.max_bytes),
        else: acc.buffer |> Enum.reverse() |> IO.iodata_to_binary()

    {output, tail_truncated, _info} =
      BashExecutor.truncate_tail(full, max_bytes: acc.max_bytes, max_lines: @max_lines)

    truncated = tail_truncated or acc.total_bytes > acc.max_bytes

    path =
      cond do
        truncated and acc.path ->
          acc.path

        truncated ->
          path = temp_path()

          {:ok, :ok} =
            File.open(path, [:write, :binary, :exclusive], fn file ->
              File.chmod!(path, 0o600)
              IO.binwrite(file, full)
            end)

          path

        true ->
          if acc.path, do: File.rm(acc.path)
          nil
      end

    %{output: output, truncated: truncated, full_output_path: path}
  end

  defp flush_tail(%{utf8_tail: ""} = acc), do: acc
  defp flush_tail(acc), do: store(%{acc | utf8_tail: ""}, "�")

  defp store(acc, ""), do: acc

  defp store(acc, text) do
    acc = %{
      acc
      | total_bytes: acc.total_bytes + byte_size(text),
        newline_terminated: String.ends_with?(text, "\n")
    }

    cond do
      acc.file ->
        IO.binwrite(acc.file, text)
        acc

      acc.total_bytes > acc.max_bytes * 2 ->
        path = temp_path()
        {:ok, file} = File.open(path, [:write, :binary, :exclusive])
        File.chmod!(path, 0o600)
        IO.binwrite(file, Enum.reverse([text | acc.buffer]))
        %{acc | file: file, path: path, buffer: []}

      true ->
        %{acc | buffer: [text | acc.buffer]}
    end
  end

  defp read_tail(path, max_bytes) do
    {:ok, output} =
      File.open(path, [:read, :binary], fn file ->
        {:ok, size} = :file.position(file, :eof)
        {:ok, _} = :file.position(file, max(size - max_bytes, 0))

        case IO.binread(file, max_bytes) do
          :eof -> ""
          bytes -> trim_continuation_bytes(bytes)
        end
      end)

    output
  end

  defp trim_continuation_bytes(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: trim_continuation_bytes(rest)

  defp trim_continuation_bytes(bytes), do: bytes

  defp decode_utf8(data, acc) do
    case :unicode.characters_to_binary(data, :utf8, :utf8) do
      text when is_binary(text) ->
        {IO.iodata_to_binary(Enum.reverse([text | acc])), ""}

      {:incomplete, valid, tail} ->
        {IO.iodata_to_binary(Enum.reverse([valid | acc])), tail}

      {:error, valid, <<_invalid, rest::binary>>} ->
        decode_utf8(rest, ["�", valid | acc])
    end
  end

  defp temp_path do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "lemon-eval-#{random}.log")
  end
end

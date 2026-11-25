defmodule CodingAgent.Tools.BoundedInflate do
  @moduledoc false

  # Streaming, abort-aware decompression shared by archive reads, in-place
  # archive writes and SVGZ. Output is produced in `:zlib.safeInflate/2`
  # slices and rejected as soon as it passes the caller's byte limit, so a
  # high-ratio bomb or a member whose declared size lies never materialises.

  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @default_max_entries 65_536
  @default_max_decoded_bytes 256 * 1024 * 1024
  @local_header 0x04034B50

  @doc "Maximum archive entries accepted (`:format_max_archive_entries`)."
  def max_entries(opts), do: Keyword.get(opts, :format_max_archive_entries, @default_max_entries)

  @doc "Maximum total decoded bytes for one archive (`:format_max_decoded_bytes`)."
  def max_decoded_bytes(opts),
    do: Keyword.get(opts, :format_max_decoded_bytes, @default_max_decoded_bytes)

  def check_entries(count, opts) do
    limit = max_entries(opts)

    if count > limit,
      do:
        {:error,
         "Archive has #{count} entries, exceeding the #{limit}-entry limit (:format_max_archive_entries)"},
      else: :ok
  end

  @doc """
  Gunzips `bytes` without producing more than `limit` bytes.
  Returns `{:error, :too_large}` or `{:error, :invalid}` on failure.
  """
  def gunzip(bytes, limit, signal), do: inflate_with(bytes, 31, limit, signal)

  @doc """
  Inflates one ZIP member through `pread.(offset, length)`. `offset` and
  `comp_size` come from the central directory (`:zip.list_dir/1`), `declared`
  is the declared uncompressed size. Output past `min(declared, limit)` is
  rejected during inflate.
  """
  def zip_member(pread, offset, comp_size, declared, limit, signal) do
    with :ok <- check_abort(signal),
         {:ok,
          <<@local_header::little-32, _version::16, flags::little-16, method::little-16,
            _time::32, crc::little-32, _csize::32, _usize::32, name_len::little-16,
            extra_len::little-16>>} <- read_exact(pread, offset, 30),
         :ok <- not_encrypted(flags),
         {:ok, data} <- read_exact(pread, offset + 30 + name_len + extra_len, comp_size),
         {:ok, bytes} <- decode(method, data, min(declared, limit), signal),
         :ok <- check_size(bytes, declared, limit),
         :ok <- check_crc(flags, crc, bytes) do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  defp read_exact(pread, offset, length) do
    case pread.(offset, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      _ -> {:error, :invalid}
    end
  end

  defp not_encrypted(flags) when Bitwise.band(flags, 1) == 1, do: {:error, :invalid}
  defp not_encrypted(_flags), do: :ok

  defp decode(0, data, limit, _signal) when byte_size(data) > limit, do: {:error, :too_large}
  defp decode(0, data, _limit, _signal), do: {:ok, data}
  defp decode(8, data, limit, signal), do: inflate_with(data, -15, limit, signal)
  defp decode(_method, _data, _limit, _signal), do: {:error, :unsupported}

  defp check_size(bytes, declared, limit) do
    cond do
      byte_size(bytes) > limit -> {:error, :too_large}
      byte_size(bytes) != declared -> {:error, :invalid}
      true -> :ok
    end
  end

  # Bit 3: sizes and CRC live in a trailing data descriptor; the local header CRC is zero.
  defp check_crc(flags, crc, bytes) do
    if Bitwise.band(flags, 8) == 8 or :erlang.crc32(bytes) == crc,
      do: :ok,
      else: {:error, :invalid}
  end

  defp inflate_with(bytes, window_bits, limit, signal) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, window_bits)

      with {:ok, content} <- inflate(z, bytes, signal, limit, []) do
        :ok = :zlib.inflateEnd(z)
        {:ok, content}
      end
    rescue
      ErlangError -> {:error, :invalid}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, bytes, signal, remaining, chunks) do
    with :ok <- check_abort(signal) do
      {status, output} = :zlib.safeInflate(z, bytes)
      size = IO.iodata_length(output)

      cond do
        size > remaining -> {:error, :too_large}
        status == :finished -> {:ok, IO.iodata_to_binary(Enum.reverse([output | chunks]))}
        size == 0 -> {:error, :invalid}
        true -> inflate(z, <<>>, signal, remaining - size, [output | chunks])
      end
    end
  end
end

defmodule CodingAgent.ResourceLoader.SourceReader do
  @moduledoc """
  Bounded, stat-validated reads of prompt source files: instruction files,
  their `@` imports and rule files.

  Every read takes a byte cap (`:max_bytes`): at most that many bytes reach the
  caller, valid UTF-8 cut on a character boundary, with `truncated: true` and a
  warning naming the path when the file was longer. The caller renders the
  truncation marker.

  Sessions recompose their system prompt on every turn, so reads are cached in
  the calling process (the `CodingAgent.Session` GenServer, which therefore
  holds one cache per session) keyed by path, root and cap, and revalidated by
  `stat` before use: inode, device, size, mtime and ctime must be unchanged. An
  entry whose mtime is not older than the second it was read in is re-read, so
  a same-size rewrite within that second (by the session's own write or edit
  tools or anything else) is not missed despite the one-second timestamp
  resolution. The cache holds at most 1024 entries and 8 MiB of read content
  per process and is dropped whole when full. `memo/3` caches a value derived
  from read content (parsed rules)
  the same way.

  Confined reads (a `LemonCore.TrustedRoot` root) resolve the path inside the
  root as `LemonCore.TrustedRoot.read/3` does and refuse a file that was
  replaced, hard-linked or changed during the read. `:unconfined` reads
  (home-owned global files) read any regular file.

  Telemetry: `[:coding_agent, :prompt_sources, :read]` with `%{bytes: n}` and
  `%{truncated: boolean}` for every disk read (cache misses only), and
  `[:coding_agent, :prompt_sources, :load]` from `span/2` with `%{duration:,
  reads:, bytes:}` and `%{source: atom}` for a whole loader pass.
  """

  require Logger

  alias LemonCore.TrustedRoot

  @cache_key {__MODULE__, :entries}
  @bytes_key {__MODULE__, :bytes}
  @max_entries 1024
  @max_bytes 8 * 1024 * 1024

  @type result :: %{content: String.t(), real: String.t(), truncated: boolean()}

  @doc """
  Read at most `:max_bytes` bytes of `path`. `root` is a trusted root or
  `:unconfined`. Returns `:error` when the file is missing, not admitted, not
  UTF-8 text, or changed while being read.
  """
  @spec read(String.t(), String.t() | :unconfined, keyword()) :: {:ok, result()} | :error
  def read(path, root, opts) do
    max_bytes = Keyword.fetch!(opts, :max_bytes)

    with {:ok, real} <- resolve(path, root),
         {:ok, stat} <- stat(real, root) do
      key = {:read, real, root, max_bytes}

      case lookup(key, stat) do
        {:ok, result} -> {:ok, result}
        :miss -> read_and_store(key, real, root, stat, max_bytes)
      end
    else
      _ -> :error
    end
  end

  @doc """
  Cache `fun.()` under `key` for this `input`: the cached value is reused
  while an equal input is passed again (input built from `read/3` results, so
  a stat-unchanged file yields the identical binary).
  """
  @spec memo(term(), term(), (-> value)) :: value when value: term()
  def memo(key, content, fun) do
    entries = entries()

    case Map.fetch(entries, {:memo, key}) do
      {:ok, {^content, value}} ->
        value

      _ ->
        value = fun.()
        put(entries, {:memo, key}, {content, value}, 0)
        value
    end
  end

  @doc """
  Run a loader pass and emit `[:coding_agent, :prompt_sources, :load]` with
  its duration and the disk reads and bytes it performed.
  """
  @spec span(atom(), (-> value)) :: value when value: term()
  def span(source, fun) do
    outer = Process.get({__MODULE__, :span})
    Process.put({__MODULE__, :span}, {0, 0})
    started = System.monotonic_time()

    try do
      fun.()
    after
      {reads, bytes} = Process.get({__MODULE__, :span})

      case outer do
        nil ->
          Process.delete({__MODULE__, :span})

        {outer_reads, outer_bytes} ->
          Process.put({__MODULE__, :span}, {outer_reads + reads, outer_bytes + bytes})
      end

      :telemetry.execute(
        [:coding_agent, :prompt_sources, :load],
        %{duration: System.monotonic_time() - started, reads: reads, bytes: bytes},
        %{source: source}
      )
    end
  end

  @doc """
  Cut `text` to at most `max_bytes` bytes, moving the cut back to the start of
  a UTF-8 character it would split.
  """
  @spec truncate_utf8(binary(), non_neg_integer()) :: binary()
  def truncate_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text
  def truncate_utf8(text, max_bytes), do: binary_part(text, 0, boundary(text, max_bytes, 3))

  # The byte at `cut` is the first one dropped; a continuation byte there
  # means the cut splits a character.
  defp boundary(text, cut, steps) when cut > 0 and steps > 0 do
    if Bitwise.band(:binary.at(text, cut), 0xC0) == 0x80,
      do: boundary(text, cut - 1, steps - 1),
      else: cut
  end

  defp boundary(_text, cut, _steps), do: cut

  defp resolve(path, :unconfined), do: {:ok, path}
  defp resolve(path, root), do: TrustedRoot.file(path, root)

  defp stat(real, :unconfined) do
    case File.stat(real, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp stat(real, _root) do
    case File.lstat(real, time: :posix) do
      {:ok, %File.Stat{type: :regular, links: 1} = stat} -> {:ok, stat}
      _ -> :error
    end
  end

  defp stat_key(%File.Stat{} = stat),
    do: {stat.inode, stat.major_device, stat.minor_device, stat.size, stat.mtime, stat.ctime}

  defp lookup(key, stat) do
    stat_key = stat_key(stat)

    case Map.fetch(entries(), key) do
      {:ok, {^stat_key, read_at, result}} when stat.mtime < read_at -> {:ok, result}
      _ -> :miss
    end
  end

  defp read_and_store(key, real, root, before, max_bytes) do
    read_at = System.os_time(:second)

    with {:ok, data} <- read_prefix(real, max_bytes + 1),
         {:ok, after_stat} <- stat(real, root),
         true <- stat_key(after_stat) == stat_key(before),
         truncated = byte_size(data) > max_bytes,
         content = truncate_utf8(data, max_bytes),
         true <- String.valid?(content) do
      count_read(byte_size(data), truncated)

      if truncated do
        Logger.warning(
          "Truncated prompt source #{real}: #{before.size} bytes exceed the #{max_bytes}-byte limit"
        )
      end

      result = %{content: content, real: real, truncated: truncated}
      put(entries(), key, {stat_key(before), read_at, result}, byte_size(content))
      {:ok, result}
    else
      _ -> :error
    end
  end

  defp read_prefix(path, bytes) do
    case File.open(path, [:read, :binary], &IO.binread(&1, bytes)) do
      {:ok, :eof} -> {:ok, ""}
      {:ok, data} when is_binary(data) -> {:ok, data}
      _ -> :error
    end
  end

  defp count_read(bytes, truncated) do
    case Process.get({__MODULE__, :span}) do
      {reads, total} -> Process.put({__MODULE__, :span}, {reads + 1, total + bytes})
      nil -> :ok
    end

    :telemetry.execute(
      [:coding_agent, :prompt_sources, :read],
      %{bytes: bytes},
      %{truncated: truncated}
    )
  end

  defp entries, do: Process.get(@cache_key, %{})

  defp put(entries, key, value, bytes) do
    cached = Process.get(@bytes_key, 0)

    {entries, cached} =
      if map_size(entries) >= @max_entries or cached + bytes > @max_bytes,
        do: {%{}, 0},
        else: {entries, cached}

    Process.put(@bytes_key, cached + bytes)
    Process.put(@cache_key, Map.put(entries, key, value))
  end
end

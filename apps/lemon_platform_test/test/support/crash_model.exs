defmodule LemonPlatformTest.Testing.CrashModel do
  @moduledoc false

  # A deliberately small persistence model, not an alternative production backend.
  # Frames are length-prefixed terms. Only sync/1 advances the stable-byte fence.
  defmodule JournalBackend do
    @moduledoc false
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts) do
      path = Keyword.fetch!(opts, :path)
      bytes = if File.exists?(path), do: File.read!(path), else: <<>>
      {rows, complete} = decode(bytes, %{}, 0)
      File.write!(path, binary_part(bytes, 0, complete))
      {:ok, %{path: path, rows: rows}}
    end

    @impl true
    def put(state, table, key, value), do: append(state, {:put, table, key, value})

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.rows, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    @impl true
    def get(state, table, key), do: {:ok, Map.get(state.rows, {table, key}), state}

    @impl true
    def delete(state, table, key), do: append(state, {:delete, table, key})

    @impl true
    def list(state, table) do
      values = for {{^table, key}, value} <- state.rows, do: {key, value}
      {:ok, values, state}
    end

    @impl true
    def sync(state) do
      :ok = LemonCore.Durable.sync_file(state.path)
      File.write!(state.path <> ".synced", Integer.to_string(File.stat!(state.path).size))
      {:ok, state}
    end

    defp append(state, operation) do
      bytes = :erlang.term_to_binary(operation)
      File.write!(state.path, [<<byte_size(bytes)::unsigned-big-32>>, bytes], [:append])
      {:ok, %{state | rows: apply_operation(state.rows, operation)}}
    end

    defp decode(<<size::unsigned-big-32, rest::binary>>, rows, complete)
         when byte_size(rest) >= size do
      <<bytes::binary-size(^size), tail::binary>> = rest
      operation = :erlang.binary_to_term(bytes, [:safe])
      decode(tail, apply_operation(rows, operation), complete + 4 + size)
    end

    defp decode(_torn_suffix, rows, complete), do: {rows, complete}

    defp apply_operation(rows, {:put, table, key, value}),
      do: Map.put(rows, {table, key}, value)

    defp apply_operation(rows, {:delete, table, key}), do: Map.delete(rows, {table, key})
  end

  def samples(generator, seed, count \\ 24) do
    generator
    |> StreamData.resize(12)
    |> StreamData.list_of(length: count)
    |> StreamData.seeded(seed)
    |> Enum.at(0)
  end

  def start_store!(name, path) do
    opts = [
      name: name,
      backend: JournalBackend,
      backend_opts: [path: path],
      cached_tables: [],
      finalize_run_hooks: []
    ]

    ExUnit.Callbacks.start_supervised!(%{
      id: make_ref(),
      start: {LemonCore.Store, :start_link, [opts]},
      restart: :temporary
    })
  end

  def crash!(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, :killed} -> :ok
    after
      1_000 -> raise "crash model owner did not terminate"
    end
  end

  def synced_offset(path), do: path |> Kernel.<>(".synced") |> File.read!() |> String.to_integer()

  def cut!(path, offset) do
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, offset))
  end

  # The adversary may retain any prefix after the last acknowledged barrier.
  def crash_cut!(pid, path, selector) do
    floor = synced_offset(path)
    size = File.stat!(path).size
    offset = floor + rem(selector, size - floor + 1)
    crash!(pid)
    cut!(path, offset)
    offset
  end
end

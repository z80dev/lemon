defmodule LemonControlPlane.LogRing do
  @moduledoc """
  Bounded in-memory tail of the runtime's `:logger` events, read by `logs.tail`.

  The server owns a public ETS table and installs a `:logger` handler
  (`#{inspect(__MODULE__)}`) that writes each event into one of 1000
  slots, so memory stays fixed no matter how much is logged. Messages are
  formatted once, truncated to 2 KB and stored with their level, millisecond
  timestamp and module. Redaction happens in `logs.tail` on the way out.

  `get_logs/2` returns `{:ok, entries}` with the newest `limit` entries, oldest
  first, or `{:error, :unavailable}` when the ring is not running. `level` is a
  minimum severity (`"warning"` returns warning, error, critical, alert and
  emergency); `nil` returns every level.
  """

  use GenServer

  @table __MODULE__
  @handler_id :lemon_control_plane_log_ring
  @capacity 1_000
  @max_message_bytes 2_048

  @severity %{
    debug: 0,
    info: 1,
    notice: 2,
    warning: 3,
    error: 4,
    critical: 5,
    alert: 6,
    emergency: 7
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Newest `limit` entries at or above `level` (nil = all), oldest first."
  @spec get_logs(pos_integer(), String.t() | nil) :: {:ok, [map()]} | {:error, :unavailable}
  def get_logs(limit, level) when is_integer(limit) and limit > 0 do
    # The table is owned by the ring server; it is absent while that server is down.
    if :ets.whereis(@table) == :undefined do
      {:error, :unavailable}
    else
      minimum = min_severity(level)

      entries =
        @table
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {{:slot, _}, seq, entry} -> [{seq, entry}]
          _ -> []
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&(Map.get(@severity, &1.level, 0) >= minimum))
        |> Enum.take(-limit)
        |> Enum.map(&project/1)

      {:ok, entries}
    end
  end

  def get_logs(_limit, _level), do: {:ok, []}

  # -- :logger handler callbacks ---------------------------------------------

  @doc false
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    seq = :ets.update_counter(@table, :seq, {2, 1}, {:seq, 0})

    entry = %{
      level: level,
      timestamp_ms: timestamp_ms(meta),
      module: module_name(meta),
      message: format(msg, meta)
    }

    :ets.insert(@table, {{:slot, rem(seq, @capacity)}, seq, entry})
    :ok
  rescue
    _ -> :ok
  end

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    _ = :logger.remove_handler(@handler_id)
    :ok = :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :logger.remove_handler(@handler_id)
    :ok
  end

  # -- Helpers -------------------------------------------------------------------

  defp project(entry) do
    %{
      "timestampMs" => entry.timestamp_ms,
      "level" => Atom.to_string(entry.level),
      "module" => entry.module,
      "message" => entry.message
    }
  end

  defp min_severity(nil), do: 0

  defp min_severity(level) when is_binary(level) do
    case String.downcase(level) do
      "warn" ->
        @severity.warning

      "err" ->
        @severity.error

      name ->
        Enum.find_value(@severity, 0, fn {key, value} -> Atom.to_string(key) == name && value end)
    end
  end

  defp min_severity(_level), do: 0

  defp timestamp_ms(%{time: time}) when is_integer(time), do: div(time, 1000)
  defp timestamp_ms(_meta), do: System.system_time(:millisecond)

  defp module_name(%{mfa: {module, _fun, _arity}}) when is_atom(module),
    do: module |> Atom.to_string() |> String.replace_prefix("Elixir.", "")

  defp module_name(_meta), do: nil

  defp format({:string, chardata}, _meta), do: chardata |> IO.chardata_to_string() |> truncate()

  defp format({:report, report}, %{report_cb: callback}) when is_function(callback, 1) do
    {format, args} = callback.(report)
    format |> :io_lib.format(args) |> IO.chardata_to_string() |> truncate()
  end

  defp format({:report, report}, _meta), do: report |> inspect(limit: 20) |> truncate()

  defp format({format, args}, _meta) do
    format |> :io_lib.format(args) |> IO.chardata_to_string() |> truncate()
  end

  defp format(other, _meta), do: other |> inspect(limit: 20) |> truncate()

  defp truncate(text) when byte_size(text) <= @max_message_bytes, do: text

  defp truncate(text) do
    text
    |> binary_part(0, @max_message_bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
    |> Kernel.<>("…")
  end
end

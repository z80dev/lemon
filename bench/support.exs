defmodule LemonBench do
  @moduledoc """
  Shared helpers for the `bench/` suites.

  Every suite runs under `mix run --no-start`, so nothing in the umbrella is
  started for us. Each suite starts exactly the processes it measures and
  nothing else — an agent runtime booting cron jobs and channel adapters in the
  background is the fastest way to publish numbers that mean nothing.
  """

  @doc """
  Prints the machine and runtime the numbers came from.

  Benchee prints its own configuration banner; this adds the facts a reader
  needs to decide whether our numbers transfer to their hardware.
  """
  def banner(suite_name) do
    IO.puts("""

    #{String.duplicate("=", 72)}
    #{suite_name}
    #{String.duplicate("=", 72)}
    elixir           #{System.version()}
    otp              #{System.otp_release()}
    schedulers       #{System.schedulers_online()} online / #{System.schedulers()} total
    cpu              #{cpu_model()}
    os               #{os_description()}
    run at           #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """)
  end

  @doc """
  Measures a concurrent workload: `workers` processes each running `fun.(worker_index)`
  `per_worker` times. Returns `{ops_per_second, wall_time_us}`.

  Benchee measures the latency of one operation at a time; this measures what
  the system does when many processes pile onto a shared resource, which is the
  question that matters for a serialising GenServer.
  """
  def throughput(workers, per_worker, fun) do
    parent = self()

    {us, :ok} =
      :timer.tc(fn ->
        pids =
          for w <- 1..workers do
            spawn_link(fn ->
              for i <- 1..per_worker, do: fun.(w, i)
              send(parent, {:done, self()})
            end)
          end

        for pid <- pids do
          receive do
            {:done, ^pid} -> :ok
          after
            120_000 -> raise "throughput worker timed out"
          end
        end

        :ok
      end)

    total_ops = workers * per_worker
    {total_ops * 1_000_000 / us, us}
  end

  @doc "Rounds a number to `decimals` places and renders it as a string."
  def num(value, decimals \\ 2) do
    (value * 1.0) |> Float.round(decimals) |> to_string()
  end

  @doc "Formats an ops/sec figure with thousands separators."
  def fmt_ops(ops) when is_float(ops) or is_integer(ops) do
    ops
    |> round()
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  @doc "Prints a labelled ops/sec row for hand-rolled throughput measurements."
  def report(label, ops, us, total_ops) do
    IO.puts(
      String.pad_trailing(label, 46) <>
        String.pad_leading(fmt_ops(ops), 14) <>
        " ops/s" <>
        "   (#{total_ops} ops in #{Float.round(us / 1000, 1)} ms)"
    )
  end

  @doc """
  A scratch directory for suites that touch disk.

  Honours TMPDIR so benchmark databases never land on a small tmpfs, where the
  numbers would measure the ramdisk rather than the code.
  """
  def scratch_dir(name) do
    base = System.get_env("TMPDIR") || System.tmp_dir!()
    dir = Path.join([base, "lemon-bench", "#{name}-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(dir)
    dir
  end

  defp cpu_model do
    case File.read("/proc/cpuinfo") do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.find_value("unknown", fn line ->
          case String.split(line, ":", parts: 2) do
            ["model name" <> _, model] -> String.trim(model)
            _ -> nil
          end
        end)

      _ ->
        "unknown"
    end
  end

  defp os_description do
    {os_family, os_name} = :os.type()
    "#{os_family}/#{os_name}"
  end
end

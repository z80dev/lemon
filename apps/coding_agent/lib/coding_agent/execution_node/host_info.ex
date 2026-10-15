defmodule CodingAgent.ExecutionNode.HostInfo do
  @moduledoc false

  def get(opts) do
    cwd = (Keyword.get(opts, :default_cwd) || System.user_home!()) |> Path.expand()
    {family, os} = Keyword.get(opts, :platform, :os.type())
    {mem_total, mem_free, uptime} = resources(os)
    {disk_total, disk_free} = disk(cwd)

    snapshot =
      %{
        "hostname" => hostname(),
        "os" => Atom.to_string(os),
        "osVersion" => os_version(family, os),
        "arch" => :erlang.system_info(:system_architecture) |> List.to_string(),
        "cpuCount" => cpu_count(os),
        "memTotalBytes" => mem_total,
        "memFreeBytes" => mem_free,
        "diskTotalBytes" => disk_total,
        "diskFreeBytes" => disk_free,
        "uptimeSec" => uptime,
        "lemonVersion" => version(),
        "defaultCwd" => cwd,
        "user" => command("id", ["-un"])
      }

    required_strings = [
      "hostname",
      "os",
      "osVersion",
      "arch",
      "lemonVersion",
      "defaultCwd",
      "user"
    ]

    positive = ["cpuCount", "memTotalBytes", "diskTotalBytes"]
    nonnegative = ["memFreeBytes", "diskFreeBytes", "uptimeSec"]

    if os in [:linux, :darwin] and
         Enum.all?(required_strings, &(is_binary(snapshot[&1]) and snapshot[&1] != "")) and
         Enum.all?(positive, &(is_integer(snapshot[&1]) and snapshot[&1] > 0)) and
         Enum.all?(nonnegative, &(is_integer(snapshot[&1]) and snapshot[&1] >= 0)) do
      {:ok, snapshot}
    else
      {:error, :host_metrics_unavailable}
    end
  end

  defp resources(:linux) do
    memory =
      case File.read("/proc/meminfo") do
        {:ok, text} -> text
        _ -> ""
      end

    uptime =
      case File.read("/proc/uptime") do
        {:ok, text} ->
          case Float.parse(text) do
            {seconds, _} -> trunc(seconds)
            :error -> nil
          end

        _ ->
          nil
      end

    {kilobytes(memory, "MemTotal"), kilobytes(memory, "MemFree"), uptime}
  end

  defp resources(:darwin) do
    total = command("sysctl", ["-n", "hw.memsize"]) |> number()
    vm = command("vm_stat", []) || ""
    page_size = capture_number(vm, ~r/page size of (\d+) bytes/)
    free_pages = capture_number(vm, ~r/Pages free:\s+(\d+)/)

    free =
      if is_integer(page_size) and is_integer(free_pages), do: page_size * free_pages, else: nil

    boot = command("sysctl", ["-n", "kern.boottime"]) || ""
    seconds = capture_number(boot, ~r/sec = (\d+)/)
    uptime = if is_integer(seconds), do: max(System.system_time(:second) - seconds, 0), else: nil
    {total, free, uptime}
  end

  defp resources(_), do: {nil, nil, nil}

  defp disk(cwd) do
    case command("df", ["-Pk", cwd]) do
      nil ->
        {nil, nil}

      output ->
        # POSIX df columns: filesystem, 1024-blocks, used, available, capacity,
        # mount. Match the numeric columns even when the filesystem has spaces.
        case Regex.run(~r/\s(\d+)\s+\d+\s+(\d+)\s+\d+%\s/, output) do
          [_, total, free] -> {String.to_integer(total) * 1024, String.to_integer(free) * 1024}
          _ -> {nil, nil}
        end
    end
  end

  defp kilobytes(text, key) do
    case capture_number(text, Regex.compile!("^" <> key <> ":\\s+(\\d+)\\s+kB", "m")) do
      nil -> nil
      value -> value * 1024
    end
  end

  defp capture_number(text, regex) do
    case Regex.run(regex, text) do
      [_, value] -> number(value)
      _ -> nil
    end
  end

  defp number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp cpu_count(os) do
    case :erlang.system_info(:logical_processors) do
      count when is_integer(count) and count > 0 ->
        count

      _ ->
        case os do
          :darwin -> command("sysctl", ["-n", "hw.logicalcpu"]) |> number()
          :linux -> command("getconf", ["_NPROCESSORS_ONLN"]) |> number()
          _ -> nil
        end
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> nil
    end
  end

  defp os_version(:unix, :darwin), do: command("sw_vers", ["-productVersion"])

  defp os_version(_, _) do
    case :os.version() do
      {major, minor, patch} -> Enum.join([major, minor, patch], ".")
      value when is_list(value) -> List.to_string(value)
      _ -> nil
    end
  end

  defp version, do: LemonCore.Update.Version.current()

  # Measurement failures fail the whole host snapshot, not fabricated metrics.
  defp command(name, args) do
    case CodingAgent.ExecutionNode.HostCommand.run(name, args) do
      {:ok, output} -> output
      {:error, _} -> nil
    end
  end
end

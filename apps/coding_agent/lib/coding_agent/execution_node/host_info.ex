defmodule CodingAgent.ExecutionNode.HostInfo do
  @moduledoc false

  def get(opts) do
    cwd = (Keyword.get(opts, :default_cwd) || System.user_home!()) |> Path.expand()
    {family, os} = :os.type()
    {mem_total, mem_free, uptime} = resources(os)
    {disk_total, disk_free} = disk(cwd)

    {:ok,
     %{
       "hostname" => hostname(),
       "os" => Atom.to_string(os),
       "osVersion" => os_version(family, os),
       "arch" => :erlang.system_info(:system_architecture) |> List.to_string(),
       "cpuCount" => cpu_count(),
       "memTotalBytes" => mem_total,
       "memFreeBytes" => mem_free,
       "diskTotalBytes" => disk_total,
       "diskFreeBytes" => disk_free,
       "uptimeSec" => uptime,
       "lemonVersion" => version(),
       "defaultCwd" => cwd,
       "user" => command("id", ["-un"])
     }}
  end

  defp resources(:linux) do
    memory = case File.read("/proc/meminfo") do
      {:ok, text} -> text
      _ -> ""
    end
    uptime = case File.read("/proc/uptime") do
      {:ok, text} ->
        case Float.parse(text) do
          {seconds, _} -> trunc(seconds)
          :error -> nil
        end
      _ -> nil
    end
    {kilobytes(memory, "MemTotal"), kilobytes(memory, "MemFree"), uptime}
  end

  defp resources(:darwin) do
    total = command("sysctl", ["-n", "hw.memsize"]) |> number()
    vm = command("vm_stat", []) || ""
    page_size = capture_number(vm, ~r/page size of (\d+) bytes/)
    free_pages = capture_number(vm, ~r/Pages free:\s+(\d+)/)
    free = if is_integer(page_size) and is_integer(free_pages), do: page_size * free_pages, else: nil
    boot = command("sysctl", ["-n", "kern.boottime"]) || ""
    seconds = capture_number(boot, ~r/sec = (\d+)/)
    uptime = if is_integer(seconds), do: max(System.system_time(:second) - seconds, 0), else: nil
    {total, free, uptime}
  end
  defp resources(_), do: {nil, nil, nil}

  defp disk(cwd) do
    case command("df", ["-Pk", cwd]) do
      nil -> {nil, nil}
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

  defp cpu_count do
    case :erlang.system_info(:logical_processors) do
      count when is_integer(count) and count > 0 -> count
      _ -> nil
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

  # No shell interpolation or caller-controlled executable/options. Failure is
  # unavailable (null), never an invented zero or an exception string.
  defp command(name, args) do
    case System.find_executable(name) do
      nil -> nil
      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
          {output, 0} when byte_size(output) <= 65_536 -> String.trim(output)
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end
end

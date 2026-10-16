defmodule LemonCore.BrowserProvider.LCUProbe do
  @moduledoc """
  Read-only LCU browser availability, independent of the computer-use runtime.

  An installed CLI or enabled extension is not a live connection. The installed
  `lcu browser status` command must succeed, and a passive process snapshot must
  show Chrome owning this installation's native relay with its original native
  host child still running. LCU 0.9.x status explicitly does not check the live
  connection, so its exit status alone is never sufficient.

  No setup, install, MCP server, browser, or application is started. `:executable`,
  `:root`, and `:processes` (a ps-format snapshot) are injectable for tests.
  """

  alias LemonCore.BrowserProvider.Command
  alias LemonCore.Secrets.SourceRunner

  @connected "LCU Chrome extension is connected through this installation's relay."
  @missing "LCU is not installed; install it separately or select another browser provider."
  @setup "LCU Chrome extension or relay is not configured; check lcu browser status."
  @foreign "LCU is installed, but Chrome's native-host connector points to another host, not LCU's relay; check lcu browser status."
  @disconnected "LCU Chrome extension is not connected through its relay; reconnect the extension and check lcu browser status."
  @timeout "LCU browser check timed out; check lcu browser status or select another provider."
  @unavailable "LCU live connection could not be checked; check lcu browser status or select another provider."

  @spec available?(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def available?(opts \\ []) do
    root = root(opts)
    executable = Keyword.get(opts, :executable, Path.join(root, "bin/lcu"))
    timeout = Keyword.get(opts, :timeout_ms, 2_000)

    case Command.run([executable, "browser", "status"],
           timeout_ms: timeout,
           env: %{"PYTHONDONTWRITEBYTECODE" => "1"},
           accept_nonzero: true
         ) do
      {:ok, %{status: 0}} ->
        case processes(opts, timeout) do
          {:ok, snapshot} ->
            if connected?(snapshot, root), do: {:ok, @connected}, else: {:error, @disconnected}

          {:error, :timeout} ->
            {:error, @timeout}

          _ ->
            {:error, @unavailable}
        end

      {:ok, %{output: output}} ->
        if String.contains?(output, "not this LCU installation's relay"),
          do: {:error, @foreign},
          else: {:error, @setup}

      {:error, :binary_missing} ->
        {:error, @missing}

      {:error, :timeout} ->
        {:error, @timeout}

      _ ->
        {:error, @unavailable}
    end
  rescue
    _ -> {:error, @unavailable}
  catch
    _, _ -> {:error, @unavailable}
  end

  @doc false
  def reasons, do: [@connected, @missing, @setup, @foreign, @disconnected, @timeout, @unavailable]

  defp root(opts) do
    computer_use = Keyword.get(opts, :computer_use, %{})

    configured =
      Keyword.get(opts, :root) || System.get_env("LEMON_COMPUTER_USE_LCU_ROOT") ||
        value(computer_use, :lcu_root) || Application.get_env(:lemon_computer_use, :lcu_root)

    if is_binary(configured) and String.trim(configured) != "" do
      Path.expand(configured)
    else
      candidates = [Path.expand("~/.local/share/lcu/current"), "/opt/lcu/current"]
      Enum.find(candidates, hd(candidates), &File.dir?/1)
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_, _), do: nil

  defp processes(opts, timeout) do
    case Keyword.fetch(opts, :processes) do
      {:ok, snapshot} when is_binary(snapshot) ->
        {:ok, snapshot}

      {:ok, _} ->
        {:error, :invalid_config}

      :error ->
        Command.run(["ps", "-x", "-o", "pid=,ppid=,command="],
          timeout_ms: timeout,
          max_output_bytes: 1_048_576
        )
    end
  end

  defp connected?(snapshot, root) do
    with {:ok, source} <- bounded_read(Path.join(root, "lcu/native_host.py"), 65_536),
         {:ok, app} <- canonical_path(Path.join(root, "app")) do
      processes = parse_processes(snapshot)

      Enum.any?(processes, fn {pid, process} ->
        Enum.any?(relay_paths(process.command), fn script ->
          directory = Path.dirname(script)

          with {:ok, ^source} <- bounded_read(script, 65_536),
               {:ok, marker} <- bounded_read(Path.join(directory, ".lcu-browser-host"), 4_096),
               true <- marker == app <> "\n" do
            chrome_ancestor?(processes, process.parent, MapSet.new([pid])) and
              native_host_child?(processes, pid, directory)
          else
            _ -> false
          end
        end)
      end)
    else
      _ -> false
    end
  end

  defp parse_processes(snapshot) do
    snapshot
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.+)$/, line) do
        [_, pid, parent, command] ->
          Map.put(acc, String.to_integer(pid), %{
            parent: String.to_integer(parent),
            command: command
          })

        _ ->
          acc
      end
    end)
  end

  # ps does not quote argv. Try only absolute suffixes ending at the exact relay
  # script name, then attest the file bytes and installation marker, rather than
  # splitting on spaces (the user's paths may contain them).
  defp relay_paths(command) do
    case :binary.match(command, "/lcu-native-host.py") do
      {ending, length} ->
        finish = ending + length
        prefix = binary_part(command, 0, finish)
        suffix = binary_part(command, finish, byte_size(command) - finish)

        if suffix == "" or String.starts_with?(suffix, " ") do
          for {offset, 1} <- :binary.matches(prefix, "/"),
              offset == 0 or binary_part(prefix, offset - 1, 1) == " ",
              do: binary_part(prefix, offset, byte_size(prefix) - offset)
        else
          []
        end

      :nomatch ->
        []
    end
  end

  defp chrome_ancestor?(processes, pid, seen) do
    if MapSet.member?(seen, pid) or MapSet.size(seen) >= 64 do
      false
    else
      case Map.get(processes, pid) do
        nil ->
          false

        process ->
          chrome?(process.command) or
            chrome_ancestor?(processes, process.parent, MapSet.put(seen, pid))
      end
    end
  end

  defp chrome?(command) do
    not Regex.match?(~r{(?:Google Chrome(?: (?:Beta|Dev|Canary))?|Chromium) Helper\b}, command) and
      Regex.match?(
        ~r{(?:^|/)(?:Google Chrome(?: (?:Beta|Dev|Canary))?|Chromium|google-chrome(?:-stable|-beta|-unstable)?|chromium(?:-browser)?)(?:\s|$)},
        command
      )
  end

  defp native_host_child?(processes, pid, directory) do
    hosts =
      for {platform, binary} <- [{"macos", "ChatGPT for Chrome"}, {"linux", "extension-host"}],
          arch <- ["arm64", "x64"],
          do: Path.join([directory, "chrome/extension-host", platform, arch, binary])

    Enum.any?(processes, fn {_child_pid, child} ->
      child.parent == pid and
        Enum.any?(hosts, fn host ->
          (child.command == host or String.starts_with?(child.command, host <> " ")) and
            SourceRunner.executable_available?(host)
        end)
    end)
  end

  defp bounded_read(path, limit) do
    with {:ok, %{size: size}} when size <= limit <- File.stat(path),
         {:ok, data} when byte_size(data) <= limit <- File.read(path) do
      {:ok, data}
    else
      _ -> :error
    end
  end

  defp canonical_path(path, depth \\ 0)
  defp canonical_path(_, depth) when depth > 32, do: :error

  defp canonical_path(path, depth) do
    [root | parts] = path |> Path.expand() |> Path.split()

    Enum.reduce_while(parts, {:ok, root}, fn part, {:ok, base} ->
      candidate = Path.join(base, part)

      case File.read_link(candidate) do
        {:ok, target} ->
          target = Path.expand(target, Path.dirname(candidate))

          case canonical_path(target, depth + 1) do
            {:ok, resolved} -> {:cont, {:ok, resolved}}
            _ -> {:halt, :error}
          end

        {:error, :einval} ->
          {:cont, {:ok, candidate}}

        _ ->
          {:halt, :error}
      end
    end)
  end
end

defmodule CodingAgent.TestHostCapabilities do
  @moduledoc false

  @browser_driver Path.expand(
                    "../../../../clients/lemon-browser-node/dist/local-driver.js",
                    __DIR__
                  )

  # The real-browser smoke drives the built lemon-browser-node local driver
  # (`npm ci && npm run build` in clients/lemon-browser-node; dist/ is ignored)
  # against a Chrome/Chromium executable.
  def browser_driver do
    cond do
      is_nil(System.find_executable("node")) -> {:error, :node_missing}
      not File.regular?(@browser_driver) -> {:error, :driver_not_built}
      is_nil(chrome_executable()) -> {:error, :chrome_missing}
      true -> :ok
    end
  end

  def browser_driver_path, do: @browser_driver

  # The coding_agent suite isolates HOME. On macOS, Chrome under a HOME without
  # a login keychain stalls every network request on cookie encryption, so the
  # smoke launches it through a wrapper adding `--use-mock-keychain` (the macOS
  # counterpart of the driver's `--password-store=basic`). Other hosts use
  # Chrome directly.
  def isolated_home_chrome(dir) do
    chrome = chrome_executable()

    case :os.type() do
      {:unix, :darwin} ->
        wrapper = Path.join(dir, "chrome-mock-keychain")
        quoted = "'" <> String.replace(chrome, "'", "'\\''") <> "'"
        File.write!(wrapper, "#!/bin/sh\nexec #{quoted} --use-mock-keychain \"$@\"\n")
        File.chmod!(wrapper, 0o755)
        wrapper

      _ ->
        chrome
    end
  end

  def chrome_executable do
    [
      System.get_env("LEMON_BROWSER_EXECUTABLE"),
      System.get_env("LEMON_CHROME_EXECUTABLE"),
      System.get_env("CHROME_EXECUTABLE"),
      System.find_executable("google-chrome"),
      System.find_executable("google-chrome-stable"),
      System.find_executable("chromium"),
      System.find_executable("chromium-browser")
    ]
    |> Enum.find(fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  # Finding lldb-dap is insufficient on macOS: task_for_pid permission may be
  # denied specifically to non-interactive sessions. Exercise a real launch once
  # before choosing the integration exclusions, not in each individual test.
  def lldb_launch do
    compiler = System.find_executable("clang") || System.find_executable("cc")
    debugger = System.find_executable("lldb")

    with {:ok, _} <- CodingAgent.Debug.Adapters.select_launch("/x/a.c", "/", "lldb-dap", :file),
         true <- is_binary(compiler) and is_binary(debugger) do
      probe_launch(compiler, debugger)
    else
      _ -> {:error, :missing_debugger_or_compiler}
    end
  end

  defp probe_launch(compiler, debugger) do
    root = Path.join(System.tmp_dir!(), "lemon-lldb-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    try do
      source = Path.join(root, "main.c")
      program = Path.join(root, "main")

      File.write!(
        source,
        "#include <stdio.h>\nint main(void) { puts(\"LEMON_LLDB_LAUNCH_OK\"); return 0; }\n"
      )

      with {:ok, _, 0} <- command(compiler, ["-g", "-O0", "-o", program, source]),
           {:ok, output, 0} <- command(debugger, ["--batch", "-o", "run", "--", program]),
           true <- String.contains?(output, "LEMON_LLDB_LAUNCH_OK") do
        :ok
      else
        {:ok, _, _} -> {:error, :launch_denied}
        {:error, reason} -> {:error, reason}
        false -> {:error, :launch_unavailable}
      end
    after
      File.rm_rf!(root)
    end
  end

  defp command(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    timer = Process.send_after(self(), {:probe_timeout, port}, 30_000)

    try do
      collect(port, [])
    after
      Process.cancel_timer(timer)
      if Port.info(port), do: Port.close(port)

      receive do
        {:probe_timeout, ^port} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp collect(port, output) do
    receive do
      {^port, {:data, data}} -> collect(port, [data | output])
      {^port, {:exit_status, status}} -> {:ok, IO.iodata_to_binary(Enum.reverse(output)), status}
      {:probe_timeout, ^port} -> {:error, :probe_timeout}
    end
  end
end

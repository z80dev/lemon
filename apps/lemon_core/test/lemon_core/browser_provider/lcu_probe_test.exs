defmodule LemonCore.BrowserProvider.LCUProbeTest do
  use ExUnit.Case, async: false

  alias LemonCore.BrowserProvider.LCUProbe

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "installed release")
    relay = Path.join(dir, "private relay")
    script = Path.join(relay, "lcu-native-host.py")
    app = Path.join(root, "app")
    host = Path.join(relay, "chrome/extension-host/linux/x64/extension-host")
    argv = Path.join(dir, "argv.log")
    executable = Path.join(root, "bin/lcu")
    source = "# installed relay implementation\n"

    for path <- [
          app,
          Path.dirname(script),
          Path.dirname(host),
          Path.dirname(executable),
          Path.join(root, "lcu")
        ] do
      File.mkdir_p!(path)
    end

    File.write!(Path.join(root, "lcu/native_host.py"), source)
    File.write!(script, source)
    File.write!(Path.join(relay, ".lcu-browser-host"), app <> "\n")
    File.write!(host, "#!/bin/sh\nexit 0\n")
    File.chmod!(host, 0o700)
    status_script(executable, argv)

    processes = """
    1 0 /sbin/launchd
    10 1 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --profile-directory=Default
    20 10 /usr/bin/python3 #{script} chrome-extension://example/
    21 20 #{host} chrome-extension://example/
    """

    %{
      root: root,
      relay: relay,
      script: script,
      app: app,
      host: host,
      argv: argv,
      executable: executable,
      processes: processes
    }
  end

  test "connected Chrome through the installed relay is available, with status-only argv",
       fixture do
    assert {:ok, reason} = probe(fixture)
    assert reason =~ "connected through"
    assert File.read!(fixture.argv) == "browser\nstatus\n"
  end

  test "extension-enabled status alone never counts as a live connection", fixture do
    assert {:error, reason} = probe(fixture, processes: "1 0 /sbin/launchd\n")
    assert reason =~ "not connected"
    assert File.read!(fixture.argv) == "browser\nstatus\n"
  end

  test "status failure prevents process evidence from overriding missing setup", fixture do
    status_script(
      fixture.executable,
      fixture.argv,
      "printf 'private token /Users/private/path\\n'\nexit 1\n"
    )

    assert {:error, reason} = probe(fixture)
    assert reason =~ "not configured"
    refute reason =~ "private"
  end

  test "known foreign connector output is classified without exposing its path", fixture do
    body =
      "printf '%s\\n' \"Chrome connector: the native-host manifest points to /private/other/host, not this LCU installation's relay.\"\nexit 1\n"

    status_script(fixture.executable, fixture.argv, body)
    assert {:error, reason} = probe(fixture)
    assert reason =~ "installed"
    assert reason =~ "another host, not LCU"
    refute reason =~ "/private"
  end

  test "a Codex-owned or other Chrome native connector is not LCU", fixture do
    File.write!(Path.join(fixture.relay, ".lcu-browser-host"), "/Applications/Codex.app\n")
    assert {:error, reason} = probe(fixture)
    assert reason =~ "not connected"
    refute reason =~ "Codex.app"
  end

  test "foreign or outdated relay code is not accepted", fixture do
    File.write!(fixture.script, "# different implementation\n")
    assert {:error, _} = probe(fixture)
  end

  test "relay must have both Chrome ancestry and a live original host child", fixture do
    no_chrome =
      String.replace(
        fixture.processes,
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Codex.app/Contents/MacOS/Codex"
      )

    assert {:error, _} = probe(fixture, processes: no_chrome)

    no_child =
      fixture.processes
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "21 "))
      |> Enum.join("\n")

    assert {:error, _} = probe(fixture, processes: no_child)

    wrong_parent = String.replace(fixture.processes, "21 20 ", "21 1 ")
    assert {:error, _} = probe(fixture, processes: wrong_parent)
  end

  test "host executable and exact command must match the relay's bundled host", fixture do
    File.chmod!(fixture.host, 0o600)
    assert {:error, _} = probe(fixture)
    File.chmod!(fixture.host, 0o700)

    assert {:error, _} =
             probe(fixture,
               processes:
                 String.replace(fixture.processes, fixture.host, fixture.host <> "-foreign")
             )
  end

  test "Chrome helpers and cyclic or malformed snapshots cannot forge Chrome ancestry", fixture do
    helper =
      String.replace(
        fixture.processes,
        "Google Chrome --profile",
        "Google Chrome Helper --profile"
      )

    assert {:error, _} = probe(fixture, processes: helper)
    cyclic = String.replace(fixture.processes, "20 10 ", "20 20 ")
    assert {:error, _} = probe(fixture, processes: cyclic)
    assert {:error, _} = probe(fixture, processes: "malformed process snapshot")
  end

  test "installation and app symlinks resolve to the marker's real app", fixture do
    selected = Path.join(Path.dirname(fixture.root), "selected")
    File.ln_s!(fixture.root, selected)
    assert {:ok, _} = LCUProbe.available?(root: selected, processes: fixture.processes)
  end

  test "missing CLI and unavailable process snapshots fail closed", fixture do
    assert {:error, reason} = probe(fixture, executable: Path.join(fixture.root, "missing"))
    assert reason =~ "not installed"
    assert {:error, reason} = probe(fixture, processes: false)
    assert reason =~ "could not be checked"
  end

  test "status timeout and oversized output are bounded and redacted", fixture do
    status_script(fixture.executable, fixture.argv, "while :; do :; done\n")
    assert {:error, reason} = probe(fixture, timeout_ms: 1_000)
    assert reason =~ "timed out"
    assert File.read!(fixture.argv) == "browser\nstatus\n"

    status_script(
      fixture.executable,
      fixture.argv,
      "while :; do printf 'private token private path private output\\n'; done\n"
    )

    assert {:error, reason} = probe(fixture, timeout_ms: 1_000)
    refute reason =~ "private"
  end

  defp probe(fixture, extra \\ []) do
    LCUProbe.available?(
      Keyword.merge(
        [root: fixture.root, executable: fixture.executable, processes: fixture.processes],
        extra
      )
    )
  end

  defp status_script(
         executable,
         argv,
         body \\ "printf 'Chrome extension: enabled.\\nChrome connector: configured for this LCU installation.\\nLive browser connection: not checked.\\n'\n"
       ) do
    File.write!(executable, "#!/bin/sh\nprintf '%s\\n' \"$@\" > #{shell_quote(argv)}\n" <> body)
    File.chmod!(executable, 0o700)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

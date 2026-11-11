defmodule LemonCli.LauncherSupervisionTest do
  @moduledoc """
  Shell-level tests for the supervisor-aware launcher paths: `controller_unit`
  ownership detection, manager hand-off in `start_daemon`/`restart`, the
  supervision line in `status`, the authenticated `__update-daemon stop TOKEN`
  takeover hook, and the post-VM uninstall manifest.

  Both launchers are exercised through stub `launchctl`, `systemctl`, `curl`,
  `mix`, `elixir` and release binaries; no real service manager, port or
  process is touched.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @root Path.expand("../../../..", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    release = Path.join(tmp_dir, "release")
    tools = Path.join(tmp_dir, "tools")
    home = Path.join(tmp_dir, "home")

    for dir <- [Path.join(source, "bin"), Path.join(release, "bin"), tools, home] do
      File.mkdir_p!(dir)
    end

    File.cp!(Path.join(@root, "bin/lemon"), Path.join(source, "bin/lemon"))
    registry = "apps/lemon_cli/lib/lemon_cli/command_registry.ex"
    File.mkdir_p!(Path.dirname(Path.join(source, registry)))
    File.cp!(Path.join(@root, registry), Path.join(source, registry))
    File.mkdir_p!(Path.join(source, "scripts"))
    File.cp!(Path.join(@root, "rel/overlays/bin/lemon"), Path.join(release, "bin/lemon"))

    for destination <- [Path.join(source, "rel/overlays/libexec"), Path.join(release, "libexec")] do
      File.mkdir_p!(destination)

      File.cp!(
        Path.join(@root, "rel/overlays/libexec/lemon-uninstall"),
        Path.join(destination, "lemon-uninstall")
      )
    end

    health = Path.join(tmp_dir, "health")
    calls = Path.join(tmp_dir, "calls")
    File.write!(calls, "")

    executable(Path.join(tools, "mix"), "exit 0")
    executable(Path.join(tools, "sleep"), "exit 0")

    executable(Path.join(tools, "curl"), """
    printf '%s' "$(cat "$TEST_HEALTH_FILE" 2>/dev/null)"
    """)

    # launchd stub: `print` succeeds only for a loaded label, `kickstart`
    # records the exact invocation and publishes health.
    executable(Path.join(tools, "launchctl"), """
    printf '%s\\n' "launchctl $*" >> "$TEST_CALLS"
    case "$1" in
      print) [ "${TEST_LAUNCHD_LOADED:-0}" = 1 ] || exit 1 ;;
      kickstart) printf '%s' "${TEST_HEALTH_BODY:-}" > "$TEST_HEALTH_FILE" ;;
    esac
    exit 0
    """)

    executable(Path.join(tools, "systemctl"), """
    printf '%s\\n' "systemctl $*" >> "$TEST_CALLS"
    case "$2" in
      is-enabled) [ "${TEST_SYSTEMD_ENABLED:-0}" = 1 ] || exit 1 ;;
      start|restart) printf '%s' "${TEST_HEALTH_BODY:-}" > "$TEST_HEALTH_FILE" ;;
    esac
    exit 0
    """)

    executable(Path.join(release, "bin/lemon_runtime_min"), """
    printf '%s\\n' "release $1" >> "$TEST_CALLS"
    case "$1" in
      daemon) exit 0 ;;
      pid) printf '%s\\n' "${TEST_RUNTIME_PID:-}" ;;
      rpc) printf '%s:%s\\n' "${TEST_RPC_PID:-}" "${LEMON_CONTROL_PLANE_PORT:-}" ;;
      eval)
        if [ -n "${TEST_MANIFEST_BODY:-}" ] && [ -n "${LEMON_UNINSTALL_MANIFEST:-}" ]; then
          printf '%s' "$TEST_MANIFEST_BODY" > "$LEMON_UNINSTALL_MANIFEST"
        fi
        exit "${TEST_CLI_STATUS:-0}"
        ;;
      *) exit 0 ;;
    esac
    """)

    executable(Path.join(tools, "elixir"), """
    printf '%s\\n' "elixir $*" >> "$TEST_CALLS"
    if [ -n "${TEST_MANIFEST_BODY:-}" ] && [ -n "${LEMON_UNINSTALL_MANIFEST:-}" ]; then
      printf '%s' "$TEST_MANIFEST_BODY" > "$LEMON_UNINSTALL_MANIFEST"
    fi
    exit "${TEST_CLI_STATUS:-0}"
    """)

    overrides =
      ~w(LEMON_CONTROL_PLANE_OPERATOR_TOKEN LEMON_RUNTIME_PID_FILE LEMON_RUNTIME_LOG_FILE
      LEMON_CONTROL_PLANE_PORT LEMON_WEB_PORT LEMON_SIM_UI_PORT RELEASE_TMP RELEASE_COOKIE
      TEST_LAUNCHD_LOADED TEST_SYSTEMD_ENABLED TEST_MANIFEST_BODY TEST_CLI_STATUS TEST_RPC_PID)

    port = free_port()

    env =
      Enum.map(overrides, &{&1, nil}) ++
        [
          {"HOME", home},
          {"XDG_CONFIG_HOME", Path.join(home, ".config")},
          {"PATH", tools <> ":" <> System.get_env("PATH")},
          {"LEMON_CONTROL_PLANE_PORT", Integer.to_string(port)},
          {"LEMON_WEB_PORT", "49180"},
          {"LEMON_SIM_UI_PORT", "49190"},
          {"LEMON_SECRETS_MASTER_KEY", String.duplicate("a", 64)},
          {"RELEASE_COOKIE", "isolated-launcher-test"},
          {"LEMON_WEB_SECRET_KEY_BASE", String.duplicate("b", 64)},
          {"TEST_HEALTH_FILE", health},
          {"TEST_HEALTH_BODY", ~s({"ok":true})},
          {"TEST_CALLS", calls},
          {"ERL_FLAGS", "+S 2:2"}
        ]

    {:ok,
     source: source,
     release: release,
     tools: tools,
     home: home,
     env: env,
     port: port,
     health: health,
     calls: calls}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # controller_unit ownership
  # ──────────────────────────────────────────────────────────────────────────

  test "status reports a loaded Lemon-owned launchd controller unit", ctx do
    label = launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    env = put(ctx.env, "TEST_LAUNCHD_LOADED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "supervised by launchd (#{label})"
      assert output =~ "log: ~/.lemon/logs/controller.log"
      refute output =~ "not supervised"
    end
  end

  test "XML-escaped launcher paths are recognized without double decoding", ctx do
    home = Path.join(ctx.tmp_dir, "home &amp; <studio> \"quoted\" 'name'")
    File.mkdir_p!(home)
    label = launchd_plist(home, ctx.port, "#{home}/.lemon/bin/lemon")
    env = ctx.env |> put("HOME", home) |> put("TEST_LAUNCHD_LOADED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "supervised by launchd (#{label})"
    end
  end

  test "status reports an enabled Lemon-owned systemd controller unit", ctx do
    unit = systemd_unit(ctx.home, ctx.port, "# Managed by lemon service (role=controller)")
    env = put(ctx.env, "TEST_SYSTEMD_ENABLED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "supervised by systemd (#{unit})"
      refute output =~ "not supervised"
    end
  end

  test "status reports not supervised without a unit file", ctx do
    env = put(ctx.env, "TEST_LAUNCHD_LOADED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a unit file that is not loaded is not treated as supervising", ctx do
    launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    systemd_unit(ctx.home, ctx.port, "# Managed by lemon service (role=controller)")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], ctx.env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a foreign unit under the Lemon label is never adopted", ctx do
    launchd_plist(ctx.home, ctx.port, "/usr/local/bin/something-else")
    systemd_unit(ctx.home, ctx.port, "# somebody else's unit", "/usr/local/bin/other")

    env =
      ctx.env
      |> put("TEST_LAUNCHD_LOADED", "1")
      |> put("TEST_SYSTEMD_ENABLED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a plist whose program only mentions Lemon in its environment is foreign", ctx do
    # The exact failure mode: a foreign job whose PATH contains ~/.lemon/bin.
    label = "org.lemon.controller.#{ctx.port}"
    dir = Path.join([ctx.home, "Library", "LaunchAgents"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, label <> ".plist"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>#{label}</string>
      <key>ProgramArguments</key><array><string>/bin/sleep</string><string>100000</string></array>
      <key>EnvironmentVariables</key><dict>
        <key>PATH</key><string>#{ctx.home}/.lemon/bin/lemon:/usr/bin</string>
      </dict>
    </dict></plist>
    """)

    systemd_unit(ctx.home, ctx.port, "# unrelated", "/bin/sleep")

    env =
      ctx.env
      |> put("TEST_LAUNCHD_LOADED", "1")
      |> put("TEST_SYSTEMD_ENABLED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a plist carrying another label is not ours", ctx do
    label = "org.lemon.controller.#{ctx.port}"
    dir = Path.join([ctx.home, "Library", "LaunchAgents"])
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, label <> ".plist"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>com.example.other</string>
      <key>ProgramArguments</key><array><string>#{ctx.home}/.lemon/bin/lemon</string></array>
    </dict></plist>
    """)

    env = put(ctx.env, "TEST_LAUNCHD_LOADED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a symlinked unit file is never trusted", ctx do
    label = launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    unit = systemd_unit(ctx.home, ctx.port, "# Managed by lemon service (role=controller)")
    plist = Path.join([ctx.home, "Library", "LaunchAgents", label <> ".plist"])
    unit_path = Path.join([ctx.home, ".config", "systemd", "user", unit])

    for path <- [plist, unit_path] do
      target = path <> ".real"
      File.rename!(path, target)
      File.ln_s!(target, path)
    end

    env =
      ctx.env
      |> put("TEST_LAUNCHD_LOADED", "1")
      |> put("TEST_SYSTEMD_ENABLED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "not supervised: run 'lemon service install controller'"
    end
  end

  test "a systemd unit is owned by its ExecStart launcher without the header", ctx do
    unit = systemd_unit(ctx.home, ctx.port, "# local tweak", "#{ctx.home}/.lemon/bin/lemon")
    env = put(ctx.env, "TEST_SYSTEMD_ENABLED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} = launch(root, ["status"], env)
      assert output =~ "supervised by systemd (#{unit})"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # start_daemon hand-off
  # ──────────────────────────────────────────────────────────────────────────

  test "daemon starts a supervised controller through launchd, not the release", ctx do
    label = launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    env = put(ctx.env, "TEST_LAUNCHD_LOADED", "1")
    uid = uid()

    assert {output, 0} = launch(ctx.release, ["daemon"], env)
    assert output =~ "started via launchd (#{label})"

    calls = File.read!(ctx.calls)
    assert calls =~ "launchctl kickstart gui/#{uid}/#{label}"
    refute calls =~ "launchctl kickstart -k"
    refute calls =~ "release daemon"
  end

  test "daemon starts a supervised controller through systemd, not mix", ctx do
    unit = systemd_unit(ctx.home, ctx.port, "# Managed by lemon service (role=controller)")
    env = put(ctx.env, "TEST_SYSTEMD_ENABLED", "1")

    assert {output, 0} = launch(ctx.source, ["daemon"], env)
    assert output =~ "started via systemd (#{unit})"

    calls = File.read!(ctx.calls)
    assert calls =~ "systemctl --user start #{unit}"
    refute calls =~ "elixir"
  end

  test "an already healthy runtime is reused without touching the manager", ctx do
    launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    File.write!(ctx.health, ~s({"ok":true}))

    env = put(ctx.env, "TEST_LAUNCHD_LOADED", "1")

    for root <- [ctx.source, ctx.release] do
      assert {output, 0} = launch(root, ["daemon"], env)
      assert output =~ "reusing it"
    end

    refute File.read!(ctx.calls) =~ "kickstart"
  end

  test "an unhealthy supervised unit fails instead of starting a second runtime", ctx do
    launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")

    env =
      ctx.env
      |> put("TEST_LAUNCHD_LOADED", "1")
      |> put("TEST_HEALTH_BODY", "")

    assert {output, 1} = launch(ctx.release, ["daemon"], env)
    assert output =~ "did not become healthy"
    refute File.read!(ctx.calls) =~ "release daemon"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # restart hand-off
  # ──────────────────────────────────────────────────────────────────────────

  test "asynchronous manager restart waits for replacement identity and selected root", ctx do
    label = launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")
    unit = systemd_unit(ctx.home, ctx.port, "# Managed by lemon service (role=controller)")

    for root <- [ctx.source, ctx.release], manager <- ["launchd", "systemd"] do
      env = delayed_restart(ctx, root)

      env =
        env
        |> put("TEST_LAUNCHD_LOADED", if(manager == "launchd", do: "1", else: "0"))
        |> put("TEST_SYSTEMD_ENABLED", if(manager == "systemd", do: "1", else: "0"))

      assert {snapshot, 0} = launch(root, ["__update-daemon", "snapshot"], env)

      assert {output, 0} =
               launch(
                 root,
                 [
                   "__update-daemon",
                   "restart",
                   String.trim(snapshot),
                   Path.join(ctx.tmp_dir, "previous")
                 ],
                 env
               )

      assert output =~ "restarted selected"
      assert File.read!(Path.join(ctx.tmp_dir, "wait-count")) == "5"
      calls = File.read!(ctx.calls)

      assert calls =~
               if(manager == "launchd",
                 do: "launchctl kickstart -k gui/#{uid()}/#{label}",
                 else: "systemctl --user --no-block restart #{unit}"
               )

      refute calls =~ "release daemon"
    end
  end

  test "old healthy process never satisfies same-root supervised restart", ctx do
    launchd_plist(ctx.home, ctx.port, "#{ctx.home}/.lemon/bin/lemon")

    for root <- [ctx.source, ctx.release] do
      env = delayed_restart(ctx, root) |> put("TEST_LAUNCHD_LOADED", "1")
      File.write!(Path.join(ctx.home, ".lemon/run/lemon-#{ctx.port}.root"), root <> "\n")
      executable(Path.join(ctx.tools, "sleep"), "exit 0")
      assert {output, 1} = launch(root, ["restart"], env)
      assert output =~ "replacement runtime did not become healthy"
    end
  end

  test "restart without a unit keeps the unsupervised stop and start path", ctx do
    assert {output, 1} = launch(ctx.release, ["restart"], ctx.env)
    refute output =~ "kickstart"
    refute File.read!(ctx.calls) =~ "kickstart"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # __update-daemon stop TOKEN
  # ──────────────────────────────────────────────────────────────────────────

  test "both launchers expose the private stop hook and refuse a wrong token", ctx do
    record_runtime(ctx, ctx.release)

    for root <- [ctx.source, ctx.release] do
      assert {output, 1} =
               launch(root, ["__update-daemon", "stop", String.duplicate("f", 64)], ctx.env)

      assert output =~ "daemon changed before stop; no process was signalled"
    end
  end

  test "both launchers reject malformed private lifecycle requests", ctx do
    for root <- [ctx.source, ctx.release],
        args <- [
          ["__update-daemon", "stop"],
          ["__update-daemon", "stop", "a", "b"],
          ["__update-daemon", "bogus", "token"],
          ["__update-daemon"]
        ] do
      assert {output, 2} = launch(root, args, ctx.env)
      assert output =~ "invalid internal update lifecycle request"
    end
  end

  test "the stop hook reports a stopped runtime rather than signalling", ctx do
    for root <- [ctx.source, ctx.release] do
      assert {output, 0} = launch(root, ["__update-daemon", "snapshot"], ctx.env)
      assert String.trim(output) == "stopped"
    end
  end

  # The source record stores the start time the daemon was born with. A PID
  # that the OS later handed to another process must not be adoptable.
  test "the source snapshot refuses a record whose stored birth no longer matches", ctx do
    state = Path.join(ctx.home, ".lemon/run")
    File.mkdir_p!(state)

    File.write!(
      Path.join(state, "lemon-#{ctx.port}.pid"),
      System.pid() <> "\nWed Jan  1 00:00:00 1975\n"
    )

    File.write!(Path.join(state, "lemon-#{ctx.port}.root"), ctx.source <> "\n")

    assert {output, 0} = launch(ctx.source, ["__update-daemon", "snapshot"], ctx.env)
    assert String.trim(output) == "stopped"

    assert {stop_output, 1} =
             launch(ctx.source, ["__update-daemon", "stop", String.duplicate("a", 64)], ctx.env)

    assert stop_output =~ "no process was signalled"
    assert {_, 0} = System.cmd("/bin/kill", ["-0", System.pid()], stderr_to_stdout: true)
  end

  test "the source stop hook accepts only its own snapshot token", ctx do
    state = Path.join(ctx.home, ".lemon/run")
    File.mkdir_p!(state)

    born =
      System.cmd("ps", ["-p", System.pid(), "-o", "lstart="])
      |> elem(0)
      |> String.trim_trailing("\n")

    File.write!(Path.join(state, "lemon-#{ctx.port}.pid"), System.pid() <> "\n" <> born <> "\n")
    File.write!(Path.join(state, "lemon-#{ctx.port}.root"), ctx.source <> "\n")

    assert {snapshot, 0} = launch(ctx.source, ["__update-daemon", "snapshot"], ctx.env)
    assert String.trim(snapshot) =~ ~r/\A[0-9a-f]{64}\z/

    assert {output, 1} =
             launch(ctx.source, ["__update-daemon", "stop", String.duplicate("b", 64)], ctx.env)

    assert output =~ "daemon changed before stop; no process was signalled"
    assert {_, 0} = System.cmd("/bin/kill", ["-0", System.pid()], stderr_to_stdout: true)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # uninstall manifest
  # ──────────────────────────────────────────────────────────────────────────

  test "packaged uninstall deletes exactly the manifest paths after the VM exits", ctx do
    versions = Path.join([ctx.home, ".lemon", "versions"])
    bot = Path.join([ctx.home, ".local", "bin", "lemon-bot"])
    File.mkdir_p!(versions)
    File.mkdir_p!(Path.dirname(bot))
    File.write!(bot, "#!/bin/sh\n")

    env = put(ctx.env, "TEST_MANIFEST_BODY", manifest(ctx.home, [versions, bot]))

    assert {_output, 0} = launch(ctx.release, ["uninstall", "--confirm", "abc"], env)
    refute File.exists?(versions)
    refute File.exists?(bot)
  end

  test "source uninstall deletes manifest paths after the CLI exits", ctx do
    versions = Path.join([ctx.home, ".lemon", "versions"])
    File.mkdir_p!(versions)
    env = put(ctx.env, "TEST_MANIFEST_BODY", manifest(ctx.home, [versions]))

    assert {_output, 0} = launch(ctx.source, ["uninstall", "--confirm", "abc"], env)
    refute File.exists?(versions)
  end

  test "the launcher deletes only the canonical installer paths", ctx do
    outside = Path.join(ctx.tmp_dir, "not-lemon")
    store = Path.join([ctx.home, ".lemon", "store"])
    ssh = Path.join(ctx.home, ".ssh")
    File.mkdir_p!(outside)
    File.mkdir_p!(store)
    File.mkdir_p!(ssh)

    env = put(ctx.env, "TEST_MANIFEST_BODY", manifest(ctx.home, [outside, ssh, store, ctx.home]))

    for root <- [ctx.source, ctx.release] do
      # An unrecognized path is refused, and the refusal is an error exit.
      assert {output, 1} = launch(root, ["uninstall", "--confirm", "abc"], env)
      assert output =~ "unsafe, changed, or unrecognized path"
      assert File.exists?(outside)
      assert File.exists?(store)
      assert File.exists?(ssh)
      assert File.exists?(ctx.home)
    end
  end

  test "the launcher removes the data directory only when the CLI asks for it", ctx do
    data = Path.join(ctx.home, ".lemon")
    File.mkdir_p!(Path.join(data, "store"))
    env = put(ctx.env, "TEST_MANIFEST_BODY", manifest(ctx.home, [data]))

    assert {_output, 0} = launch(ctx.release, ["uninstall", "--purge", "--confirm", "abc"], env)
    refute File.exists?(data)
  end

  test "a failed uninstall CLI deletes nothing", ctx do
    versions = Path.join([ctx.home, ".lemon", "versions"])
    File.mkdir_p!(versions)

    env =
      ctx.env
      |> put("TEST_MANIFEST_BODY", manifest(ctx.home, [versions]))
      |> put("TEST_CLI_STATUS", "1")

    for root <- [ctx.source, ctx.release] do
      assert {_output, 1} = launch(root, ["uninstall"], env)
      assert File.exists?(versions)
    end
  end

  test "the uninstall manifest is private and removed afterwards", ctx do
    versions = Path.join([ctx.home, ".lemon", "versions"])
    File.mkdir_p!(versions)

    probe = Path.join(ctx.tmp_dir, "probe")

    executable(Path.join(ctx.tools, "elixir"), """
    printf '%s\\n' "$LEMON_UNINSTALL_MANIFEST" > "#{probe}"
    stat -f '%Lp' "$LEMON_UNINSTALL_MANIFEST" >> "#{probe}" 2>/dev/null ||
      stat -c '%a' "$LEMON_UNINSTALL_MANIFEST" >> "#{probe}" 2>/dev/null
    exit 0
    """)

    assert {_output, 0} = launch(ctx.source, ["uninstall"], ctx.env)

    [manifest, mode] = probe |> File.read!() |> String.split("\n", trim: true)

    assert String.contains?(manifest, "lemon-uninstall.")
    refute String.starts_with?(manifest, Path.join(ctx.home, ".lemon"))
    assert mode == "600"
    refute File.exists?(manifest)
    refute File.exists?(Path.dirname(manifest))
  end

  test "deferred deletion refuses swapped ancestor and leaf identities", ctx do
    for root <- [ctx.source, ctx.release], swap <- [:ancestor, :leaf] do
      base = Path.join(ctx.home, ".lemon/lemon_bot")
      target = Path.join(base, "versions")
      File.mkdir_p!(target)
      payload = manifest(ctx.home, [target])
      moved = if swap == :ancestor, do: base, else: target
      File.rename!(moved, moved <> ".old")
      File.mkdir_p!(moved)
      File.mkdir_p!(target)
      marker = Path.join(target, "keep")
      File.write!(marker, "not previewed")

      assert {output, 1} =
               launch(root, ["uninstall"], put(ctx.env, "TEST_MANIFEST_BODY", payload))

      assert output =~ "unsafe, changed, or unrecognized path"
      assert File.read!(marker) == "not previewed"
      File.rm_rf!(base)
      File.rm_rf!(base <> ".old")
    end
  end

  test "deferred deletion never follows a replaced ancestor symlink", ctx do
    outside = Path.join(ctx.tmp_dir, "outside")
    File.mkdir_p!(Path.join(outside, "versions"))
    marker = Path.join(outside, "versions/keep")
    File.write!(marker, "external")

    for root <- [ctx.source, ctx.release] do
      base = Path.join(ctx.home, ".lemon/lemon_bot")
      File.mkdir_p!(Path.join(base, "versions"))
      payload = manifest(ctx.home, [Path.join(base, "versions")])
      File.rename!(base, base <> ".old")
      File.ln_s!(outside, base)
      assert {_, 1} = launch(root, ["uninstall"], put(ctx.env, "TEST_MANIFEST_BODY", payload))
      assert File.read!(marker) == "external"
      File.rm!(base)
      File.rename!(base <> ".old", base)
    end
  end

  test "deferred deletion unlinks a leaf symlink without deleting its target", ctx do
    outside = Path.join(ctx.tmp_dir, "external")
    File.mkdir_p!(outside)

    for root <- [ctx.source, ctx.release] do
      link = Path.join(ctx.home, ".lemon/versions")
      File.mkdir_p!(Path.dirname(link))
      File.ln_s!(outside, link)
      payload = manifest(ctx.home, [link])
      assert {_, 0} = launch(root, ["uninstall"], put(ctx.env, "TEST_MANIFEST_BODY", payload))
      assert File.dir?(outside)
      assert {:error, :enoent} = File.lstat(link)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp manifest(home, paths) do
    canonical = fn path ->
      {parent, 0} = System.cmd("pwd", ["-P"], cd: Path.dirname(path))
      Path.join(String.trim(parent), Path.basename(path))
    end

    {home, 0} = System.cmd("pwd", ["-P"], cd: home)

    entries =
      Enum.map(paths, fn path ->
        path = canonical.(path)
        Map.put(file_identity(path), :ancestors, ancestors(Path.dirname(path)))
      end)

    Jason.encode!(%{schema: 2, home: String.trim(home), paths: entries})
  end

  defp ancestors("/"), do: [file_identity("/")]
  defp ancestors(path), do: ancestors(Path.dirname(path)) ++ [file_identity(path)]

  defp file_identity(path) do
    stat = File.lstat!(path)
    %{path: path, type: Atom.to_string(stat.type), device: stat.major_device, inode: stat.inode}
  end

  defp delayed_restart(ctx, target) do
    state = Path.join(ctx.home, ".lemon/run")
    File.mkdir_p!(state)
    previous = Path.join(ctx.tmp_dir, "previous")
    File.mkdir_p!(Path.join(previous, "bin"))
    File.write!(Path.join(state, "lemon-#{ctx.port}.pid"), "4242\nold\n")
    File.write!(Path.join(state, "lemon-#{ctx.port}.root"), previous <> "\n")
    File.write!(ctx.health, ~s({"ok":true}))
    File.write!(ctx.calls, "")
    count = Path.join(ctx.tmp_dir, "wait-count")
    File.write!(count, "0")

    executable(Path.join(ctx.tools, "ps"), """
    case "$*" in
      *stat=*) echo S ;;
      *lstart=*) if [ "$2" = 4242 ]; then echo old; else echo new; fi ;;
      *) exit 1 ;;
    esac
    """)

    executable(Path.join(ctx.tools, "sleep"), """
    n="$(cat "#{count}")"
    n=$((n + 1))
    printf %s "$n" > "#{count}"
    if [ "$n" = 3 ]; then printf '4343\\nnew\\n' > "#{state}/lemon-#{ctx.port}.pid"; fi
    if [ "$n" = 5 ]; then printf '%s\\n' "#{target}" > "#{state}/lemon-#{ctx.port}.root"; fi
    """)

    executable(Path.join(ctx.release, "bin/lemon_runtime_min"), """
    printf 'release %s\\n' "$1" >> "$TEST_CALLS"
    if [ "$1" = rpc ]; then
      IFS= read -r pid < "#{state}/lemon-#{ctx.port}.pid"
      printf '%s:%s\\n' "$pid" "$LEMON_CONTROL_PLANE_PORT"
    fi
    """)

    File.cp!(
      Path.join(ctx.release, "bin/lemon_runtime_min"),
      Path.join(previous, "bin/lemon_runtime_min")
    )

    ctx.env
  end

  defp launchd_plist(home, port, program) do
    label = if port == 4040, do: "org.lemon.controller", else: "org.lemon.controller.#{port}"
    dir = Path.join([home, "Library", "LaunchAgents"])
    File.mkdir_p!(dir)

    program =
      program
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&apos;")

    File.write!(Path.join(dir, label <> ".plist"), """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Label</key><string>#{label}</string>
      <key>ProgramArguments</key><array><string>#{program}</string><string>start</string></array>
    </dict></plist>
    """)

    label
  end

  defp systemd_unit(home, port, comment, program \\ nil) do
    unit =
      if port == 4040, do: "lemon-controller.service", else: "lemon-controller-#{port}.service"

    dir = Path.join([home, ".config", "systemd", "user"])
    File.mkdir_p!(dir)
    program = program || "/usr/bin/true"

    File.write!(Path.join(dir, unit), """
    #{comment}
    [Service]
    ExecStart=#{program}
    """)

    unit
  end

  # Publishes a pid/root record the private hooks can authenticate against.
  defp record_runtime(ctx, root) do
    state = Path.join(ctx.home, ".lemon/run")
    File.mkdir_p!(state)
    File.write!(Path.join(state, "lemon-#{ctx.port}.pid"), System.pid() <> "\n")
    File.write!(Path.join(state, "lemon-#{ctx.port}.root"), root <> "\n")
    :ok
  end

  defp uid, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim()

  defp launch(root, args, env) do
    System.cmd("/bin/bash", [Path.join(root, "bin/lemon") | args],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp executable(path, body) do
    File.write!(path, "#!/bin/bash\n" <> body <> "\n")
    File.chmod!(path, 0o755)
  end

  defp put(env, key, value), do: [{key, value} | Enum.reject(env, &(elem(&1, 0) == key))]

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

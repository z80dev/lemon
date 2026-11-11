defmodule LemonCore.Service.UnitTest do
  use ExUnit.Case, async: true
  alias LemonCore.Service.{Role, Unit}

  @moduletag :tmp_dir
  setup %{tmp_dir: home} do
    bot = Path.join(home, ".local/bin/lemon-bot")
    File.mkdir_p!(Path.dirname(bot))
    File.write!(bot, "#!/bin/sh\nexit 0\n")
    File.chmod!(bot, 0o700)

    {:ok,
     opts: [
       home: home,
       env: %{},
       login_path: "/usr/bin:/bin",
       name: "studio",
       controller: "ws://127.0.0.1:4044/ws",
       ssh: "me@studio",
       node_port: 4044,
       gateway_port: 4044
     ]}
  end

  test "every role has stable launchers and deliberate-stop supervision", %{opts: opts} do
    for role <- Role.roles(), manager <- ["launchd", "systemd"] do
      assert {:ok, spec} = Role.build(role, manager, opts)
      body = Unit.render(spec, manager)
      refute body =~ "/versions/"
      refute body =~ "--supervised"
      refute body =~ "LEMON_BOT_OPERATOR_TOKEN"
      refute body =~ "LEMON_BOT_ENCRYPTION_KEY"

      if manager == "launchd" do
        assert body =~ "<key>SuccessfulExit</key><false/>"
        assert body =~ "<key>RunAtLoad</key><true/>"
        assert body =~ "<integer>10</integer>"
      else
        assert body =~ "Restart=on-failure"
        assert body =~ "RestartPreventExitStatus=2"
        assert body =~ "TimeoutStopSec=30"
      end

      assert {:ok, parsed} = Unit.parse(body, manager)
      assert parsed.argv == spec.argv
      assert parsed.env == spec.env

      if role == "worker" do
        assert parsed.env["LEMON_GATEWAY_HEALTH_PORT"] == "0"
        assert parsed.env["LEMON_ROUTER_HEALTH_PORT"] == "0"
      end

      assert Unit.owned?(parsed, spec, opts)
    end
  end

  test "systemd quotes spaces and escapes expansion without executing it", %{opts: opts} do
    path = Path.join(opts[:home], "some space/%literal/$variable/bin/lemon")
    assert {:ok, spec} = Role.build("controller", "systemd", Keyword.put(opts, :launcher, path))
    body = Unit.render(spec, "systemd")
    assert body =~ "%%literal/$$variable"
    assert {:ok, %{argv: [^path, "start"]}} = Unit.parse(body, "systemd")
  end

  test "labels reflect nondefault ports and adopt existing worker names" do
    assert Role.label("controller", "launchd", nil, 4040) == "org.lemon.controller"
    assert Role.label("controller", "launchd", nil, 4140) == "org.lemon.controller.4140"
    assert Role.label("backend", "systemd", nil, 4200) == "lemon-bot-4200.service"
    assert Role.label("worker", "launchd", "studio", nil) == "org.lemon.node.studio"
    assert Role.identity("org.lemon.node.studio.plist") == {"worker", [name: "studio"]}
    assert Role.identity("lemon-node-studio.service") == {"worker", [name: "studio"]}
    assert Role.identity("org.lemon.controller.plist") == {"controller", [port: 4040]}
  end

  test "backend refuses secret environment even if the value is empty", %{opts: opts} do
    for key <- ~w(LEMON_BOT_OPERATOR_TOKEN LEMON_BOT_ENCRYPTION_KEY), value <- ["secret", ""] do
      assert {:error, :backend_secret_environment} =
               Role.build("backend", "launchd", Keyword.put(opts, :env, %{key => value}))
    end
  end

  test "backend persists only the documented nonsecret environment", %{opts: opts} do
    env = %{
      "LEMON_BOT_PORT" => "4200",
      "LEMON_BOT_PUBLIC_URL" => "https://bot.example",
      "UNRELATED_SECRET" => "no"
    }

    assert {:ok, spec} = Role.build("backend", "systemd", Keyword.put(opts, :env, env))
    assert spec.env["LEMON_BOT_PORT"] == "4200"
    refute Map.has_key?(spec.env, "UNRELATED_SECRET")
  end

  test "backend launch persists the resolved local controller port without ports.env", %{
    opts: opts
  } do
    refute File.exists?(Path.join(opts[:home], ".lemon/ports.env"))

    opts =
      Keyword.merge(opts,
        port: 4201,
        env: %{"LEMON_CONTROL_PLANE_PORT" => "4144", "LEMON_BOT_PORT" => "4200"}
      )

    for manager <- ["launchd", "systemd", "none"] do
      assert {:ok, spec} = Role.build("backend", manager, opts)
      assert {:ok, parsed} = Unit.parse(Unit.render(spec, manager), manager)
      assert parsed.env["LEMON_BOT_PORT"] == "4201"
      assert parsed.env["LEMON_CONTROL_PLANE_PORT"] == "4144"
    end
  end

  test "signed exec wrappers survive argument decoding and require executable bundles", %{
    opts: opts
  } do
    wrapper =
      Path.join(opts[:home], "Lemon Bot.app/Contents/Helpers/Worker.app/Contents/MacOS/worker")

    File.mkdir_p!(Path.dirname(wrapper))
    File.write!(wrapper, "#!/bin/sh\nexec \"$@\"\n")
    File.chmod!(wrapper, 0o700)

    assert {:ok, spec} =
             Role.build("worker", "launchd", Keyword.put(opts, :exec_wrapper, wrapper))

    assert [^wrapper, "--" | _] = spec.argv
    assert spec.env["LEMON_TCC_PROBE"] == wrapper
    assert Role.options_from_argv(spec.argv)[:exec_wrapper] == wrapper

    assert {:error, :exec_wrapper_requires_macos} =
             Role.build("worker", "systemd", Keyword.put(opts, :exec_wrapper, wrapper))

    File.rm!(wrapper)

    assert {:error, :exec_wrapper_missing} =
             Role.build("worker", "launchd", Keyword.put(opts, :exec_wrapper, wrapper))
  end

  test "tunnel environment uses the systemd agent without copying secrets", %{opts: opts} do
    runner = fn "systemctl", ["--user", "show-environment"], _ ->
      {"SSH_AUTH_SOCK=/run/user/501/ssh-agent\n", 0}
    end

    opts = Keyword.merge(opts, command_runner: runner, env: %{"SECRET_TOKEN" => "hidden"})
    assert {:ok, spec} = Role.build("tunnel", "systemd", opts)
    assert spec.env["SSH_AUTH_SOCK"] == "/run/user/501/ssh-agent"
    assert Enum.sort(Map.keys(spec.env)) == ~w(HOME PATH SSH_AUTH_SOCK)
  end

  test "foreign programs and mismatched plist labels are not owned", %{opts: opts} do
    assert {:ok, spec} = Role.build("controller", "launchd", opts)
    assert {:ok, parsed} = Unit.parse(Unit.render(spec, "launchd"), "launchd")
    refute Unit.owned?(%{parsed | argv: ["/bin/sleep", "99"]}, spec, opts)
    refute Unit.owned?(%{parsed | label: "org.other.service"}, spec, opts)
  end
end

defmodule LemonCli.BotHttpsCommandTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias LemonCli.BotHttpsCommand, as: HTTPS
  @moduletag :tmp_dir
  @native "LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS"
  @cron "LEMON_CRON_ADMISSION_ALLOWED_ORIGINS"

  setup %{tmp_dir: home} do
    File.mkdir_p!(Path.join(home, ".lemon"))
    parent = self()
    {:ok, calls} = Agent.start_link(fn -> [] end)
    record = fn call -> Agent.update(calls, &[call | &1]) end
    {:ok, backend} = Agent.start_link(fn -> %{} end)

    {:ok, running} =
      Agent.start_link(fn ->
        %{"publicUrl" => "http://127.0.0.1:4100", "firstPartyMcpApproved" => true}
      end)

    opts = [
      home: home,
      env: %{},
      mcp_policy: fn origin, _ ->
        {:ok,
         %{"origin" => origin, "allowedOrigins" => [origin], "approvedPrivateOrigins" => [origin]}}
      end,
      mcp_resolver: fn _ -> {:ok, [{100, 64, 0, 1}]} end,
      backend_env: fn -> {:ok, Agent.get(backend, & &1)} end,
      lock: fn fun -> fun.() end,
      service_install: fn roles, options ->
        record.({:install, roles, options[:bot_public_url]})

        if roles == ["backend"] do
          send(parent, {:backend_restart_requested, options[:restart_backend]})
          environment = Map.delete(options[:env] || %{}, "LEMON_BOT_PUBLIC_URL")

          environment =
            if options[:bot_public_url],
              do: Map.put(environment, "LEMON_BOT_PUBLIC_URL", options[:bot_public_url]),
              else: environment

          Agent.update(backend, fn _ -> environment end)

          if options[:restart_backend] do
            config_path =
              environment["LEMON_BOT_CONFIG_FILE"] ||
                Path.join(
                  environment["LEMON_BOT_DATA_DIR"] || Path.join(home, ".lemon/lemon_bot"),
                  "config.json"
                )

            config =
              case File.read(config_path) do
                {:ok, text} -> Jason.decode!(text)
                _ -> %{}
              end

            {:ok, public} =
              LemonMCP.HTTP.OriginPolicy.canonical_origin(
                options[:bot_public_url] || "http://127.0.0.1:4100"
              )

            uri = URI.parse(public)

            approved =
              public in (config["approvedPrivateMcpOrigins"] || []) or
                (uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"])

            Agent.update(running, fn _ ->
              %{"publicUrl" => public, "firstPartyMcpApproved" => approved}
            end)
          end
        end

        {:ok, %{units: Enum.map(roles, &%{role: &1, state: "ready"})}}
      end,
      controller_restart: fn _ ->
        record.(:restart)
        :ok
      end,
      http_get: fn url ->
        send(parent, {:identity, url})

        {:ok,
         Map.merge(
           %{"product" => "lemon_bot", "instanceId" => "same-instance"},
           Agent.get(running, & &1)
         )}
      end,
      controller_check: fn origin ->
        send(parent, {:doctor, origin})
        :ok
      end,
      backend_status: fn _ ->
        {:ok,
         %{
           "bots" => [
             %{"id" => "bot_1", "admissionState" => "configured", "nextAction" => "none"}
           ],
           "truncated" => false
         }}
      end,
      command: fn argv, _ ->
        record.({:command, argv})
        {:ok, ""}
      end
    ]

    {:ok, home: home, opts: opts, calls: calls}
  end

  test "backend policy changes restart on enable, pending retry, and disable and are checked live",
       %{home: home, opts: opts} do
    install = opts[:service_install]

    stale =
      Keyword.put(opts, :service_install, fn roles, options ->
        install.(roles, Keyword.delete(options, :restart_backend))
      end)

    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], stale)
    assert message =~ "running backend"

    assert Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))["phase"] ==
             "pending"

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert_received {:backend_restart_requested, true}
    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    assert_received {:backend_restart_requested, true}
  end

  test "first install resolves the invoking operator environment through the service installer",
       %{home: home, opts: opts} do
    bot = Path.join(home, ".local/bin/lemon-bot")
    File.mkdir_p!(Path.dirname(bot))
    File.write!(bot, "#!/bin/sh\nexit 0\n")
    File.chmod!(bot, 0o700)
    config = Path.join(home, "custom/operator.json")

    opts =
      opts
      |> Keyword.delete(:backend_env)
      |> Keyword.merge(
        os: :darwin,
        uid: "501",
        bot: bot,
        login_path: "/usr/bin:/bin",
        command_runner: fn _, _, _ -> {"", 1} end,
        env: %{
          "LEMON_BOT_CONFIG_FILE" => config,
          "LEMON_BOT_DATA_DIR" => Path.join(home, "custom/data")
        }
      )

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)

    assert Jason.decode!(File.read!(config))["approvedPrivateMcpOrigins"] == [
             "https://bot.example"
           ]

    state = Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))
    assert state["private_mcp"]["path"] == config
    refute File.exists?(Path.join(home, ".lemon/lemon_bot/config.json"))
  end

  test "a controller credential port mismatch refuses before any mutation", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    opts =
      opts
      |> Keyword.put(:backend_env, %{"LEMON_BOT_CONTROL_URL" => "ws://127.0.0.1:5050/ws"})
      |> Keyword.put(:env, %{
        "LEMON_CONTROL_PLANE_PORT" => "4040",
        "LEMON_CONTROL_PLANE_OPERATOR_TOKEN" => "never-print-this"
      })
      |> Keyword.put(:controller_check, fn _ ->
        flunk("must not authenticate with the wrong port's credential")
      end)

    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert message =~ "LEMON_CONTROL_PLANE_PORT=5050"
    refute message =~ "never-print-this"
    assert Agent.get(calls, & &1) == []
    refute File.exists?(Path.join(home, ".lemon/bot-https.json"))
    refute File.exists?(Path.join(home, ".lemon/env"))
  end

  test "MCP verification invokes the actual backend policy without runtime cache writes or credentials",
       %{home: home, opts: opts} do
    parent = self()

    opts =
      opts
      |> Keyword.delete(:mcp_policy)
      |> Keyword.put(:command, fn
        [_bot, "https-policy", "--origin", origin, "--json"], options ->
          send(parent, {:policy_environment, options[:command_env]})

          {:ok,
           Jason.encode!(%{
             "origin" => origin,
             "allowedOrigins" => [origin],
             "approvedPrivateOrigins" => [origin]
           })}
      end)

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert_received {:policy_environment, environment}
    assert environment["BUN_RUNTIME_TRANSPILER_CACHE_PATH"] == "0"
    assert environment["HOME"] == home
    assert environment["LEMON_BOT_PUBLIC_URL"] == "https://bot.example"
    refute Map.has_key?(environment, "LEMON_BOT_OPERATOR_TOKEN")
  end

  test "managed private MCP approval is exact, owned, and execution-verified", %{
    home: home,
    opts: opts
  } do
    config = Path.join(home, ".lemon/lemon_bot/config.json")
    File.mkdir_p!(Path.dirname(config))

    original = %{
      "version" => 1,
      "approvedPrivateMcpOrigins" => ["https://other.example"],
      "trustedFrontendOrigins" => ["https://frontend.example"]
    }

    File.write!(config, Jason.encode!(original))
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)

    assert Jason.decode!(File.read!(config))["approvedPrivateMcpOrigins"] == [
             "https://other.example",
             "https://bot.example"
           ]

    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    assert Jason.decode!(File.read!(config)) == original

    denied =
      Keyword.put(opts, :mcp_policy, fn origin, _ ->
        {:ok, %{"origin" => origin, "allowedOrigins" => [origin], "approvedPrivateOrigins" => []}}
      end)

    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], denied)
    assert message =~ "MCP"

    assert Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))["phase"] ==
             "pending"
  end

  test "saved remote controller refuses before any local mutation or readiness check", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    directory = Path.join(home, ".lemon/lemon_bot")
    File.mkdir_p!(directory)

    File.write!(
      Path.join(directory, "controller.json"),
      Jason.encode!(%{
        "version" => 1,
        "mode" => "remote",
        "url" => "wss://remote.example/ws",
        "token" => "never-display-this"
      })
    )

    opts =
      Keyword.put(opts, :controller_check, fn _ ->
        flunk("must not verify a different local controller")
      end)

    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert message =~ "remote controller"
    refute message =~ "never-display-this"
    assert Agent.get(calls, & &1) == []
    refute File.exists?(Path.join(home, ".lemon/bot-https.json"))
    assert {:ok, %{controller: "not confirmed"}} = HTTPS.execute(["status"], opts)
  end

  test "local controller selection uses the backend's saved port", %{opts: opts} do
    parent = self()

    opts =
      opts
      |> Keyword.put(:backend_env, %{"LEMON_CONTROL_PLANE_PORT" => "5050"})
      |> Keyword.put(:env, %{"LEMON_CONTROL_PLANE_PORT" => "5050"})
      |> Keyword.delete(:controller_check)
      |> Keyword.put(:rpc, fn _, _, rpc_opts ->
        send(parent, {:controller_url, rpc_opts[:url]})

        {:ok,
         %{
           "botPublicOrigin" => "https://bot.example",
           "checks" => [%{"name" => "bot.admission_origins", "status" => "pass"}]
         }}
      end)

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert_received {:controller_url, "ws://127.0.0.1:5050/ws"}
  end

  test "adopting a preexisting public URL and MCP approval restores both", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    previous = "https://BOT.example:443"
    opts = Keyword.put(opts, :backend_env, %{"LEMON_BOT_PUBLIC_URL" => previous})
    config = Path.join(home, ".lemon/lemon_bot/config.json")
    File.mkdir_p!(Path.dirname(config))

    File.write!(
      config,
      Jason.encode!(%{"version" => 1, "approvedPrivateMcpOrigins" => ["https://bot.example"]})
    )

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    state = Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))
    assert state["public_url"] == %{"original" => previous, "owned" => false}
    assert {:ok, %{address: "https://bot.example"}} = HTTPS.execute(["disable"], opts)
    assert {:install, ["backend"], previous} in Agent.get(calls, & &1)

    assert Jason.decode!(File.read!(config))["approvedPrivateMcpOrigins"] == [
             "https://bot.example"
           ]
  end

  test "source mode refuses before side effects and points at the manual appendix", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    opts = Keyword.put(opts, :env, %{"LEMON_CLI_LAUNCHER" => "source"})
    assert {:error, message} = HTTPS.execute(["enable", "--tailscale"], opts)
    assert message =~ "source"
    assert message =~ "manual-https-setup"
    assert Agent.get(calls, & &1) == []
    refute File.exists?(Path.join(home, ".lemon/bot-https.json"))
    refute File.exists?(Path.join(home, ".lemon/env"))
  end

  test "failed reconfiguration persists pending and retry reapplies services", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)

    File.write!(
      Path.join(home, ".lemon/env"),
      "#{@native}=http://127.0.0.1:4100\n#{@cron}=http://127.0.0.1:4100\n"
    )

    failing =
      Keyword.put(opts, :controller_restart, fn _ ->
        assert Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))["phase"] ==
                 "pending"

        {:error, :failed}
      end)

    assert {:error, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], failing)

    assert Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))["phase"] ==
             "pending"

    before_retry = length(Agent.get(calls, & &1))

    assert {:ok, %{changed: true}} =
             HTTPS.execute(["enable", "--url", "https://bot.example"], opts)

    assert length(Agent.get(calls, & &1)) > before_retry

    assert Jason.decode!(File.read!(Path.join(home, ".lemon/bot-https.json")))["phase"] ==
             "active"
  end

  test "env replacement preserves existing permissions and new env defaults private", %{
    home: home,
    opts: opts
  } do
    path = Path.join(home, ".lemon/env")
    File.write!(path, "# keep mode\n")
    File.chmod!(path, 0o640)
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o640
    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o640
    File.rm!(path)
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o600
  end

  test "enable twice is unchanged and disable removes only owned origins", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    path = Path.join(home, ".lemon/env")

    File.write!(
      path,
      "# keep\nexport #{@native}='http://127.0.0.1:4100,https://other.example'\nexport #{@cron}=http://127.0.0.1:4100\nOTHER=untouched\n"
    )

    assert {:ok, %{address: "https://bot.example", changed: true}} =
             HTTPS.execute(["enable", "--url", "https://BOT.example:443/"], opts)

    first = File.read!(path)
    receipt = Path.join(home, ".lemon/bot-https.json")
    first_inode = File.stat!(receipt).inode
    assert first =~ "https://other.example"
    assert first =~ "OTHER=untouched"
    assert_received {:doctor, "https://bot.example"}
    assert_received {:identity, "https://bot.example/v1/setup"}
    count = length(Agent.get(calls, & &1))

    assert {:ok, %{changed: false}} =
             HTTPS.execute(["enable", "--url", "https://bot.example"], opts)

    assert length(Agent.get(calls, & &1)) == count
    assert File.read!(path) == first
    assert File.stat!(receipt).inode == first_inode
    assert {:ok, %{address: nil}} = HTTPS.execute(["disable"], opts)
    restored = File.read!(path)
    refute restored =~ "https://bot.example"
    assert restored =~ "https://other.example"
    assert restored =~ "http://127.0.0.1:4100"
    assert {:install, ["backend"], nil} in Agent.get(calls, & &1)
    assert {:ok, %{changed: false}} = HTTPS.execute(["disable"], opts)
  end

  test "fresh disable restores loopback and preserves preexisting canonical origins", %{
    home: home,
    opts: opts
  } do
    path = Path.join(home, ".lemon/env")
    File.write!(path, "#{@native}=https://BOT.example:443\n")
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    assert File.read!(path) =~ "https://BOT.example:443"
    assert File.read!(path) =~ "#{@cron}='http://127.0.0.1:4100'"
  end

  test "fresh enable and disable leave only loopback in both allowlists", %{
    home: home,
    opts: opts
  } do
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    text = File.read!(Path.join(home, ".lemon/env"))
    for key <- [@native, @cron], do: assert(text =~ "#{key}='http://127.0.0.1:4100'")
    refute text =~ "https://"
    refute File.exists?(Path.join(home, ".lemon/bot-https.json"))
  end

  test "duplicate or dynamic shell allowlists fail before changing services", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    path = Path.join(home, ".lemon/env")

    for text <- ["#{@native}=a\n#{@native}=b\n", "#{@native}=\"$OTHER\"\n"] do
      File.write!(path, text)
      assert {:error, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
      assert File.read!(path) == text
      refute File.exists?(Path.join(home, ".lemon/bot-https.json"))
    end

    assert Agent.get(calls, & &1) == []
  end

  test "controller verification calls shared remote doctor with the canonical origin", %{
    opts: opts
  } do
    parent = self()

    opts =
      opts
      |> Keyword.delete(:controller_check)
      |> Keyword.put(:rpc, fn method, params, _ ->
        send(parent, {:rpc, method, params})

        {:ok,
         %{
           "botPublicOrigin" => "https://bot.example",
           "checks" => [%{"name" => "bot.admission_origins", "status" => "pass"}]
         }}
      end)

    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://BOT.example:443/"], opts)
    assert_received {:rpc, "doctor.run", %{"botPublicUrl" => "https://bot.example"}}
  end

  test "invalid URLs and conflicting arguments never mutate", %{opts: opts, calls: calls} do
    for url <- [
          "http://bot.example",
          "https://u:p@bot.example",
          "https://bot.example?q=x",
          "https://bot.example#x",
          "https://bot.example/path",
          "https://bot.example:",
          "https://bad host"
        ] do
      assert {:error, _} = HTTPS.execute(["enable", "--url", url], opts)
    end

    assert {:error, _} =
             HTTPS.execute(["enable", "--tailscale", "--url", "https://bot.example"], opts)

    assert {:error, _} = HTTPS.execute(["enable"], opts)
    assert Agent.get(calls, & &1) == []
  end

  test "status renders address allowlists and per-Bot state without credentials", %{opts: opts} do
    assert {:ok, _} = HTTPS.execute(["enable", "--url", "https://bot.example"], opts)
    output = capture_io(fn -> assert HTTPS.run(["status"], opts) == :ok end)
    assert output =~ "https://bot.example"
    assert output =~ @native <> ": allowed"
    assert output =~ "bot_1: configured"
    assert output =~ "Tailscale: not managed"
    refute output =~ "token"
  end

  test "enable and status clearly flag named Bots that cannot reply until owners update", %{
    opts: opts
  } do
    opts =
      Keyword.put(opts, :backend_status, fn _ ->
        {:ok,
         %{
           "bots" => [
             %{
               "id" => "bot_weather",
               "name" => "Weather Bot",
               "admissionState" => "configured",
               "nextAction" => "update_address"
             }
           ],
           "truncated" => true,
           "totalBots" => 203
         }}
      end)

    for args <- [["enable", "--url", "https://bot.example"], ["status"]] do
      output = capture_io(fn -> assert HTTPS.run(args, opts) == :ok end)
      assert output =~ "Weather Bot"
      assert output =~ "cannot reply"
      assert output =~ "Settings → lifecycle panel → Update address"
      assert output =~ "202 more Bots may also need Update address"
    end
  end

  test "identity mismatch and controller rejection are failures, not success", %{opts: opts} do
    mismatch =
      Keyword.put(opts, :http_get, fn url ->
        {:ok,
         %{
           "product" => "lemon_bot",
           "instanceId" => if(String.starts_with?(url, "https:"), do: "other", else: "same")
         }}
      end)

    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], mismatch)
    assert message =~ "instance"
    rejected = Keyword.put(opts, :controller_check, fn _ -> {:error, :rejected} end)
    assert {:error, message} = HTTPS.execute(["enable", "--url", "https://bot.example"], rejected)
    assert message =~ "controller"
  end

  test "disable refuses changed Tailscale handlers without touching env or services", %{
    home: home,
    opts: opts,
    calls: calls
  } do
    origin = "https://machine.example.ts.net:8443"

    state = %{
      "schema" => 2,
      "phase" => "active",
      "origin" => origin,
      "mode" => "tailscale",
      "port" => 8443,
      "target" => "http://127.0.0.1:4100",
      "added" => %{@native => [origin], @cron => [origin]},
      "public_url" => %{"original" => nil, "owned" => true},
      "private_mcp" => %{
        "path" => Path.join(home, ".lemon/lemon_bot/config.json"),
        "added" => true,
        "field_existed" => false,
        "file_existed" => false
      }
    }

    File.write!(Path.join(home, ".lemon/bot-https.json"), Jason.encode!(state))
    text = "#{@native}=http://127.0.0.1:4100,#{origin}\n"
    File.write!(Path.join(home, ".lemon/env"), text)

    opts =
      Keyword.put(opts, :command, fn
        ["tailscale", "serve", "status", "--json"], _ ->
          {:ok,
           Jason.encode!(%{
             "Web" => %{
               "machine.example.ts.net:8443" => %{
                 "Handlers" => %{
                   "/" => %{"Proxy" => "http://127.0.0.1:4100"},
                   "/other" => %{"Proxy" => "http://127.0.0.1:9999"}
                 }
               }
             }
           })}
      end)

    assert {:error, message} = HTTPS.execute(["disable"], opts)
    assert message =~ "someone else's route"
    assert File.read!(Path.join(home, ".lemon/env")) == text
    assert File.exists?(Path.join(home, ".lemon/bot-https.json"))
    assert Agent.get(calls, & &1) == []
  end

  test "tailscale selects a free route and disables only its exact owned route", %{
    opts: opts,
    calls: calls
  } do
    {:ok, route} =
      Agent.start_link(fn ->
        %{
          "Web" => %{
            "machine.example.ts.net:8443" => %{
              "Handlers" => %{"/" => %{"Proxy" => "http://127.0.0.1:9999"}}
            }
          }
        }
      end)

    command = fn
      ["tailscale", "status", "--json"] = argv, _ ->
        Agent.update(calls, &[{:command, argv} | &1])

        {:ok,
         Jason.encode!(%{
           "BackendState" => "Running",
           "Self" => %{"DNSName" => "machine.example.ts.net."}
         })}

      ["tailscale", "serve", "status", "--json"], _ ->
        {:ok, Jason.encode!(Agent.get(route, & &1))}

      ["tailscale", "serve", "--bg", "--https=8444", "http://127.0.0.1:4100"] = argv, _ ->
        Agent.update(calls, &[{:command, argv} | &1])

        Agent.update(
          route,
          &put_in(&1, ["Web", "machine.example.ts.net:8444"], %{
            "Handlers" => %{"/" => %{"Proxy" => "http://127.0.0.1:4100"}}
          })
        )

        {:ok, ""}

      ["tailscale", "serve", "--https=8444", "off"] = argv, _ ->
        Agent.update(calls, &[{:command, argv} | &1])
        {:ok, ""}
    end

    opts = Keyword.put(opts, :command, command)

    assert {:ok, %{address: "https://machine.example.ts.net:8444"}} =
             HTTPS.execute(["enable", "--tailscale"], opts)

    config = Path.join(opts[:home], ".lemon/lemon_bot/config.json")

    assert Jason.decode!(File.read!(config))["approvedPrivateMcpOrigins"] == [
             "https://machine.example.ts.net:8444"
           ]

    assert {:ok, %{changed: false}} = HTTPS.execute(["enable", "--tailscale"], opts)
    assert {:ok, _} = HTTPS.execute(["disable"], opts)
    commands = Agent.get(calls, & &1)
    assert {:command, ["tailscale", "serve", "--https=8444", "off"]} in commands

    refute Enum.any?(commands, fn
             {_, args} when is_list(args) -> "reset" in args
             _ -> false
           end)
  end
end

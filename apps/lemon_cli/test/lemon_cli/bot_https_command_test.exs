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

    opts = [
      home: home,
      env: %{},
      backend_env: fn -> {:ok, Agent.get(backend, & &1)} end,
      lock: fn fun -> fun.() end,
      service_install: fn roles, options ->
        record.({:install, roles, options[:bot_public_url]})

        if roles == ["backend"],
          do:
            Agent.update(backend, fn _ ->
              if(options[:bot_public_url],
                do: %{"LEMON_BOT_PUBLIC_URL" => options[:bot_public_url]},
                else: %{}
              )
            end)

        {:ok, %{units: Enum.map(roles, &%{role: &1, state: "ready"})}}
      end,
      controller_restart: fn _ ->
        record.(:restart)
        :ok
      end,
      http_get: fn url ->
        send(parent, {:identity, url})
        {:ok, %{"product" => "lemon_bot", "instanceId" => "same-instance"}}
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
      "schema" => 1,
      "phase" => "active",
      "origin" => origin,
      "mode" => "tailscale",
      "port" => 8443,
      "target" => "http://127.0.0.1:4100",
      "added" => %{@native => [origin], @cron => [origin]}
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

defmodule LemonBrowser.ProviderTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.{LocalServer, ProviderProbe}

  setup do
    names =
      ~w(LEMON_BROWSER_DRIVER_PATH LEMON_BROWSER_EXECUTABLE LEMON_BROWSER_CDP_ENDPOINT LEMON_BROWSER_ATTACH_ONLY LEMON_BROWSER_RELAY_TOKEN LEMON_BROWSER_RELAY_PORT LEMON_PATH)

    previous = Map.new(names, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    :ok
  end

  @tag :tmp_dir
  test "local availability reuses driver discovery without starting Chrome or the driver", %{
    tmp_dir: root
  } do
    marker = Path.join(root, "mutated")
    executable = Path.join(root, "chrome")
    File.write!(executable, "#!/bin/sh\ntouch '#{marker}'\n")
    File.chmod!(executable, 0o700)
    driver = Path.join(root, "local-driver.js")
    File.write!(driver, "throw new Error('driver must not execute');")
    File.write!(Path.join(root, "package.json"), ~s({"type":"module"}))

    File.write!(
      Path.join(root, "index.js"),
      "export function defaultChromeExecutable() { return #{Jason.encode!(executable)}; }\nexport function cdpDiscoveryUrl(endpoint) { return new URL('/json/version', endpoint); }\n"
    )

    System.put_env("LEMON_BROWSER_DRIVER_PATH", driver)

    System.put_env(
      "LEMON_BROWSER_CDP_ENDPOINT",
      "http://127.0.0.1:9/private?token=ignored-by-local"
    )

    System.put_env("LEMON_BROWSER_ATTACH_ONLY", "true")

    assert {:ok, _} = ProviderProbe.available?("local")
    refute File.exists?(marker)
    assert ProviderProbe.driver_options("local") == [cdp_endpoint: "", attach_only: false]
    assert {:ok, config} = LocalServer.configuration(ProviderProbe.driver_options("local"))
    assert config["endpoint"] == ""
    assert config["launchesBrowser"]
  end

  @tag :tmp_dir
  test "local unavailability names the missing prerequisite", %{tmp_dir: root} do
    # No override, no bundled driver in test builds, and an empty source root.
    System.put_env("LEMON_PATH", root)
    assert {:error, :driver_missing} = ProviderProbe.available?("local")

    driver = Path.join(root, "local-driver.js")
    File.write!(driver, "throw new Error('driver must not execute');")
    File.write!(Path.join(root, "package.json"), ~s({"type":"module"}))
    System.put_env("LEMON_BROWSER_DRIVER_PATH", driver)

    # A build that predates the inspection exports.
    File.write!(Path.join(root, "index.js"), "export const ChromeSession = class {};\n")
    assert {:error, :driver_incompatible} = ProviderProbe.available?("local")

    File.write!(
      Path.join(root, "index.js"),
      "export function defaultChromeExecutable() { return #{Jason.encode!(Path.join(root, "absent-chrome"))}; }\nexport function cdpDiscoveryUrl(endpoint) { return new URL('/json/version', endpoint); }\n"
    )

    assert {:error, :browser_missing} = ProviderProbe.available?("local")

    path = System.get_env("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, :node_missing} = ProviderProbe.available?("local")
    after
      System.put_env("PATH", path)
    end
  end

  @tag :tmp_dir
  test "relay requires a configured token and a connected extension", %{tmp_dir: root} do
    assert {:error, _} = ProviderProbe.available?("relay")
    driver = Path.join(root, "local-driver.js")
    File.write!(driver, "throw new Error('not executed');")
    System.put_env("LEMON_BROWSER_DRIVER_PATH", driver)
    System.put_env("LEMON_BROWSER_RELAY_TOKEN", "private-token")

    port = health_server(false)
    System.put_env("LEMON_BROWSER_RELAY_PORT", Integer.to_string(port))
    assert {:error, reason} = ProviderProbe.available?("relay")
    refute reason =~ "private-token"
    assert_receive {:health_request, request}
    assert String.downcase(request) =~ "authorization: bearer private-token"
    assert request =~ "GET /health "

    port = health_server(true)
    System.put_env("LEMON_BROWSER_RELAY_PORT", Integer.to_string(port))
    assert {:ok, _} = ProviderProbe.available?("relay")
    assert ProviderProbe.driver_options("relay")[:attach_only]
    assert ProviderProbe.driver_options("relay")[:cdp_endpoint] =~ "token=private-token"
  end

  test "explicit cdp without an endpoint is unavailable, never managed Chrome" do
    assert {:error, message} = ProviderProbe.available?("cdp")
    assert message =~ "LEMON_BROWSER_CDP_ENDPOINT"
    assert ProviderProbe.driver_options("cdp")[:attach_only]
  end

  test "unavailable providers fail closed and LCU routes callers to its own surface" do
    none = %{
      requested: "relay",
      provider: nil,
      reason: "Relay extension disconnected.",
      checks: %{}
    }

    assert {:error, "Relay extension disconnected."} =
             LemonBrowser.request("browser.tabs", %{}, 100, provider_resolution: none)

    assert %{available: false, provider_resolution: ^none} =
             LemonBrowser.status(provider_resolution: none)

    lcu = %{requested: "auto", provider: "lcu", reason: "LCU connected.", checks: %{}}

    assert {:error, message} =
             LemonBrowser.request("browser.tabs", %{}, 100, provider_resolution: lcu)

    assert message =~ "cua_js"

    assert %{available: true, provider_resolution: ^lcu} =
             LemonBrowser.status(provider_resolution: lcu)
  end

  @tag :tmp_dir
  test "selected local provider clears inherited remote CDP and attach-only settings", %{
    tmp_dir: root
  } do
    driver = Path.join(root, "fake-driver.cjs")

    File.write!(
      driver,
      "const r = require('node:readline').createInterface({input: process.stdin}); r.on('line', line => { const req = JSON.parse(line); process.stdout.write(JSON.stringify({id:req.id,ok:true,result:{endpoint:process.env.LEMON_BROWSER_CDP_ENDPOINT,attachOnly:process.env.LEMON_BROWSER_ATTACH_ONLY,args:process.argv.slice(2)}})+'\\n'); });"
    )

    server = start_supervised!({LocalServer, name: nil, driver_path: driver})
    System.put_env("LEMON_BROWSER_CDP_ENDPOINT", "ws://127.0.0.1:9?token=must-not-attach")
    System.put_env("LEMON_BROWSER_ATTACH_ONLY", "true")

    resolution = %{
      requested: "auto",
      provider: "local",
      reason: "Managed Chrome available.",
      checks: %{}
    }

    assert {:ok, result} =
             LemonBrowser.request("browser.tabs", %{}, 1_000,
               server: server,
               provider_resolution: resolution
             )

    assert result["endpoint"] in [nil, ""]
    assert result["attachOnly"] == "false"
    refute "--cdp-endpoint" in result["args"]
    refute "--attach-only" in result["args"]
    refute inspect(LocalServer.status(server)) =~ "must-not-attach"
  end

  defp health_server(connected) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    owner = self()

    pid =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener, 2_000),
             {:ok, request} <- :gen_tcp.recv(socket, 0, 2_000) do
          send(owner, {:health_request, request})
          body = Jason.encode!(%{ok: true, extensionConnected: connected})

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
                body
            )

          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    port
  end
end

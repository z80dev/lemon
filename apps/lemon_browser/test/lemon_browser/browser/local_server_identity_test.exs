defmodule LemonBrowser.LocalServerIdentityTest do
  @moduledoc """
  Each request resolves its own browser identity without changing the
  server's state. A different identity recycles an idle driver and is refused
  while another request is in flight. `stop_driver/1` (and the
  `LemonBrowser.stop_local_driver/0` facade) stops the driver on demand.
  """
  use ExUnit.Case, async: false

  alias LemonBrowser.LocalServer

  @moduletag :browser_local_server
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    if is_nil(System.find_executable("node")), do: raise("node is required")

    driver = Path.join(tmp, "driver.mjs")

    # Answers with what identifies the running driver; `args.mode == "hang"`
    # never answers.
    File.write!(driver, """
    let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', chunk => {
      buffer += chunk;
      while (true) {
        const index = buffer.indexOf('\\n');
        if (index < 0) break;
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (!line) continue;
        const request = JSON.parse(line);
        if (request.args && request.args.mode === 'hang') continue;
        process.stdout.write(JSON.stringify({id: request.id, ok: true, result: {
          pid: process.pid,
          endpoint: process.env.LEMON_BROWSER_CDP_ENDPOINT || null,
          attachOnly: process.env.LEMON_BROWSER_ATTACH_ONLY || null
        }}) + '\\n');
      }
    });
    """)

    previous = System.get_env("LEMON_BROWSER_RELAY_TOKEN")
    System.put_env("LEMON_BROWSER_RELAY_TOKEN", "identity-relay-token")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_BROWSER_RELAY_TOKEN", previous),
        else: System.delete_env("LEMON_BROWSER_RELAY_TOKEN")
    end)

    {:ok, driver: driver}
  end

  test "a provider change with no pending request recycles the driver", %{driver: driver} do
    {:ok, server} = LocalServer.start_link(name: nil, driver_path: driver)

    try do
      assert {:ok, local} = tabs(server, browser_provider: "local")
      assert local["endpoint"] == nil
      assert local["attachOnly"] == "false"

      assert {:ok, relay} = tabs(server, browser_provider: "relay")
      assert relay["pid"] != local["pid"]
      assert relay["endpoint"] =~ "/cdp?token="
      assert relay["attachOnly"] == "true"
      assert_os_process_gone(local["pid"])

      # The same identity reuses the running driver.
      assert {:ok, %{"pid" => same}} = tabs(server, browser_provider: "relay")
      assert same == relay["pid"]

      # A request never rewrites the server's own identity.
      assert :sys.get_state(server).endpoint_source == :env
      assert {:ok, %{"pid" => env_pid, "endpoint" => nil}} = tabs(server, [])
      assert env_pid != relay["pid"]
    after
      LocalServer.stop(server)
    end
  end

  test "an identity change while a request is in flight is refused", %{driver: driver} do
    {:ok, server} = LocalServer.start_link(name: nil, driver_path: driver)

    try do
      assert {:ok, %{"pid" => local_pid}} = tabs(server, browser_provider: "local")

      hung =
        Task.async(fn ->
          LocalServer.request(server, "browser.click", %{"mode" => "hang"}, 300,
            browser_provider: "local"
          )
        end)

      wait_until(fn -> LocalServer.status(server).pending_requests == 1 end)

      assert {:error, message} = tabs(server, browser_provider: "relay")
      assert message =~ "Browser identity changed while another browser request is running"
      assert {:error, :outcome_unknown} = Task.await(hung, 5_000)

      # Once idle, the change recycles.
      assert {:ok, %{"pid" => relay_pid}} = tabs(server, browser_provider: "relay")
      assert relay_pid != local_pid
    after
      LocalServer.stop(server)
    end
  end

  test "stop_driver stops the driver; the next request starts a fresh one", %{driver: driver} do
    {:ok, server} = LocalServer.start_link(name: nil, driver_path: driver)

    try do
      assert {:ok, %{"pid" => first}} = tabs(server, [])

      in_flight =
        Task.async(fn ->
          LocalServer.request(server, "browser.click", %{"mode" => "hang"}, 5_000)
        end)

      wait_until(fn -> LocalServer.status(server).pending_requests == 1 end)

      assert :ok = LocalServer.stop_driver(server)
      assert {:error, :outcome_unknown} = Task.await(in_flight, 5_000)
      assert %{running: false, pending_requests: 0} = LocalServer.status(server)
      assert_os_process_gone(first)

      assert {:ok, %{"pid" => second}} = tabs(server, [])
      assert second != first
    after
      LocalServer.stop(server)
    end
  end

  test "stop_driver ends a hosted session's server, whose endpoint is not retained", %{
    driver: driver
  } do
    {:ok, server} =
      LocalServer.start_link(
        name: nil,
        driver_path: driver,
        cdp_endpoint: "wss://hosted.test/cdp?apiKey=hosted-secret",
        attach_only: true
      )

    Process.unlink(server)
    ref = Process.monitor(server)
    assert :ok = LocalServer.stop_driver(server)
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 2_000
  end

  test "the browser facade stops the supervised local driver" do
    assert :ok = LemonBrowser.stop_local_driver()
    assert %{running: false} = LocalServer.status()
  end

  defp tabs(server, opts), do: LocalServer.request(server, "browser.tabs", %{}, 5_000, opts)

  defp assert_os_process_gone(os_pid) do
    wait_until(fn ->
      {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
      status != 0
    end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition not reached")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end
end

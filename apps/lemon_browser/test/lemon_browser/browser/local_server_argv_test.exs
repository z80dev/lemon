defmodule LemonBrowser.LocalServerArgvTest do
  @moduledoc """
  CDP endpoints carry bearer credentials (relay `?token=`, hosted provider
  URLs). They must reach the driver without appearing on its argv (visible to
  every local user through `ps`/`/proc/<pid>/cmdline`), must not be retained
  anywhere in the server's process state (closure environments included), and
  must not leak back through driver errors or status. The driver environment
  carries no inherited relay/provider credentials.
  """
  use ExUnit.Case, async: false

  alias LemonBrowser.LocalServer

  @moduletag :browser_local_server

  setup do
    if is_nil(System.find_executable("node")), do: raise("node is required")

    tmp = Path.join(System.tmp_dir!(), "lemon_argv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    driver = Path.join(tmp, "driver.mjs")

    # Echoes back what the spawned driver can observe about its launch;
    # `fail` replies with the requested error text, `exit` ends the driver.
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
        if (request.method === 'exit') process.exit(0);
        if (request.method === 'fail') {
          process.stdout.write(JSON.stringify({id: request.id, ok: false, error: request.args.error}) + '\\n');
          continue;
        }
        process.stdout.write(JSON.stringify({
          id: request.id,
          ok: true,
          result: {
            argv: process.argv.slice(2),
            endpoint: process.env.LEMON_BROWSER_CDP_ENDPOINT || null,
            attachOnly: process.env.LEMON_BROWSER_ATTACH_ONLY || null,
            env: process.env
          }
        }) + '\\n');
      }
    });
    """)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, driver: driver}
  end

  test "explicit CDP endpoint reaches the driver only through its environment", %{driver: driver} do
    secret = "argv-secret-#{System.unique_integer([:positive])}"
    endpoint = "wss://user:#{secret}@browser.test/devtools/browser?token=#{secret}"

    {:ok, pid} =
      LocalServer.start_link(
        name: nil,
        driver_path: driver,
        cdp_endpoint: endpoint,
        attach_only: true
      )

    try do
      assert {:ok, result} = LocalServer.request(pid, "browser.tabs", %{}, 5_000)
      assert result["endpoint"] == endpoint
      assert result["attachOnly"] == "true"
      refute Enum.any?(result["argv"], &(&1 =~ secret))
      refute "--cdp-endpoint" in result["argv"]
      refute "--attach-only" in result["argv"]

      os_pid = LocalServer.status(pid).port.os_pid
      {cmdline, 0} = System.cmd("ps", ["-o", "args=", "-p", Integer.to_string(os_pid)])
      refute cmdline =~ secret

      assert_no_secret(pid, secret)
    after
      LocalServer.stop(pid)
    end
  end

  test "attaching requires an explicit unenforced-egress opt-in for the driver", %{
    driver: driver
  } do
    for {opts, expected} <- [
          {[], "false"},
          {[allow_unenforced_egress: true], "true"}
        ] do
      {:ok, pid} =
        LocalServer.start_link(
          [name: nil, driver_path: driver, cdp_endpoint: "ws://127.0.0.1:1/x", attach_only: true] ++
            opts
        )

      try do
        assert {:ok, result} = LocalServer.request(pid, "browser.tabs", %{}, 5_000)
        assert result["env"]["LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS"] == expected
      after
        LocalServer.stop(pid)
      end
    end
  end

  test "a hosted driver that exits stops its server instead of keeping the endpoint", %{
    driver: driver
  } do
    {:ok, pid} =
      LocalServer.start_link(
        name: nil,
        driver_path: driver,
        cdp_endpoint: "wss://hosted.test/cdp?apiKey=hosted-secret",
        attach_only: true
      )

    Process.unlink(pid)
    ref = Process.monitor(pid)
    assert {:error, _} = LocalServer.request(pid, "exit", %{}, 2_000)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  test "relay token selected per request stays off argv and out of server state", %{
    driver: driver
  } do
    secret = "relay-secret-#{System.unique_integer([:positive])}"

    with_env(%{"LEMON_BROWSER_RELAY_TOKEN" => secret}, fn ->
      {:ok, pid} = LocalServer.start_link(name: nil, driver_path: driver)

      try do
        assert {:ok, result} =
                 LocalServer.request(pid, "browser.tabs", %{}, 5_000, browser_provider: "relay")

        assert result["endpoint"] =~ "token=#{secret}"
        assert result["attachOnly"] == "true"
        refute Enum.any?(result["argv"], &(&1 =~ secret))
        # The driver gets the endpoint it needs, not the raw relay token var.
        refute Map.has_key?(result["env"], "LEMON_BROWSER_RELAY_TOKEN")

        # The provider identity still pins the running driver.
        assert {:ok, _} =
                 LocalServer.request(pid, "browser.tabs", %{}, 5_000, browser_provider: "relay")

        assert_no_secret(pid, secret)
      after
        LocalServer.stop(pid)
      end
    end)
  end

  test "a locally launching driver inherits no relay, operator or provider credentials", %{
    driver: driver
  } do
    secrets = %{
      "LEMON_BROWSER_RELAY_TOKEN" => "relay-token-env-secret",
      "LEMON_OPERATOR_TOKEN" => "operator-token-env-secret",
      "BROWSERBASE_API_KEY" => "browserbase-env-secret",
      "CAMOFOX_API_KEY" => "camofox-env-secret",
      "LEMON_BROWSER_CDP_ENDPOINT" => "wss://inherited.test/cdp?token=inherited-env-secret",
      "LEMON_BROWSER_HEADLESS" => "true"
    }

    with_env(secrets, fn ->
      {:ok, pid} = LocalServer.start_link(name: nil, driver_path: driver)

      try do
        assert {:ok, result} =
                 LocalServer.request(pid, "browser.tabs", %{}, 5_000, browser_provider: "local")

        env = result["env"]
        assert result["attachOnly"] == "false"
        assert result["endpoint"] == nil
        assert env["LEMON_BROWSER_HEADLESS"] == "true"
        assert is_binary(env["PATH"])

        for {name, value} <- secrets, name != "LEMON_BROWSER_HEADLESS" do
          refute Map.has_key?(env, name), "driver inherited #{name}"
          refute Enum.any?(Map.values(env), &(&1 =~ value))
        end
      after
        LocalServer.stop(pid)
      end
    end)
  end

  test "driver connection failures are replied and recorded without credentials", %{
    driver: driver
  } do
    {:ok, pid} = LocalServer.start_link(name: nil, driver_path: driver)

    error =
      "CDP attach failed: connect ECONNREFUSED " <>
        "wss://alice:userinfo-secret@cdp.test:9222/devtools?apiKey=query-secret&x=other-secret#frag-secret " <>
        "Call log: <ws connecting> http://cdp.test/json/version?sessionToken=log-secret"

    try do
      assert {:error, reply} = LocalServer.request(pid, "fail", %{"error" => error}, 5_000)
      status = LocalServer.status(pid)

      for secret <- ~w(userinfo-secret query-secret other-secret frag-secret log-secret alice) do
        refute reply =~ secret
        refute inspect(status) =~ secret
      end

      assert reply =~ "ECONNREFUSED"
      assert reply =~ "wss://cdp.test:9222/devtools?apiKey=redacted&x=redacted"
    after
      LocalServer.stop(pid)
    end
  end

  defp assert_no_secret(pid, secret) do
    refute contains_secret?(:sys.get_state(pid), secret)
    refute inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity) =~ secret
  end

  # Walks the whole term, including closure environments, so a credential
  # hidden behind a fun still counts as retained.
  defp contains_secret?(term, secret) when is_binary(term), do: String.contains?(term, secret)

  defp contains_secret?(term, secret) when is_tuple(term),
    do: contains_secret?(Tuple.to_list(term), secret)

  defp contains_secret?(term, secret) when is_map(term),
    do: contains_secret?(:maps.to_list(term), secret)

  defp contains_secret?([head | tail], secret),
    do: contains_secret?(head, secret) or contains_secret?(tail, secret)

  defp contains_secret?(term, secret) when is_function(term) do
    {:env, env} = :erlang.fun_info(term, :env)
    contains_secret?(env, secret)
  end

  defp contains_secret?(_term, _secret), do: false

  defp with_env(vars, fun) do
    original = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)

    try do
      fun.()
    after
      Enum.each(original, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end

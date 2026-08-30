defmodule LemonBrowser.CloudSessionTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.{CloudSession, SessionProviderRegistry}

  defmodule HostedBrowserFakeProvider do
    @behaviour LemonBrowser.SessionProvider

    def id, do: :test_hosted
    def available?, do: true
    def available?(_opts), do: true

    def create_session(scope, opts) do
      config = Keyword.fetch!(opts, :provider_config)
      send(config.test_pid, {:created, scope})

      {:ok,
       %{
         id: "provider-#{scope}",
         cdp_endpoint: "wss://credential@browser.test/#{scope}",
         features: %{fake: true}
       }}
    end

    def close_session(id, opts) do
      config = Keyword.fetch!(opts, :provider_config)
      send(config.test_pid, {:closed, id})
      :ok
    end

    def status, do: %{provider: "test_hosted", configured: true}
  end

  setup do
    :ok = SessionProviderRegistry.register(:test_hosted, HostedBrowserFakeProvider)

    tmp =
      Path.join(System.tmp_dir!(), "lemon_cloud_session_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    driver = Path.join(tmp, "driver.mjs")

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
        process.stdout.write(JSON.stringify({
          id: request.id,
          ok: true,
          result: {method: request.method, args: request.args}
        }) + '\\n');
      }
    });
    """)

    on_exit(fn ->
      stop_fake_sessions()
      SessionProviderRegistry.unregister(:test_hosted)
      File.rm_rf!(tmp)
    end)

    {:ok, driver: driver}
  end

  test "requires an exact Lemon session binding before provider creation", %{driver: driver} do
    assert {:error, {:missing_hosted_browser_binding, :session_id}} =
             CloudSession.request(:test_hosted, "browser.tabs", %{}, 500,
               provider_config: %{test_pid: self()},
               driver_path: driver
             )

    refute_received {:created, _scope}
  end

  test "reuses one provider session per exact scope and redacts identity and CDP authority", %{
    driver: driver
  } do
    opts = [
      session_id: "session-secret-a",
      browser_profile_id: "profile-secret",
      run_id: "run-secret",
      provider_config: %{test_pid: self()},
      driver_path: driver,
      browser_idle_timeout_ms: 5_000
    ]

    assert {:ok, %{"method" => "browser.tabs"}} =
             CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, opts)

    assert {:ok, %{"method" => "browser.navigate", "args" => %{"url" => "https://example.com"}}} =
             CloudSession.request(
               :test_hosted,
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    assert_received {:created, "session-secret-a:profile-secret:run-secret"}
    refute_received {:created, _scope}

    [status] = CloudSession.status(:test_hosted)
    assert status.connected == true
    assert status.request_count == 2
    assert status.features.fake == true
    refute inspect(status) =~ "session-secret-a"
    refute inspect(status) =~ "profile-secret"
    refute inspect(status) =~ "credential"
  end

  test "different Lemon sessions never share a hosted browser and idle sessions release", %{
    driver: driver
  } do
    base = [
      provider_config: %{test_pid: self()},
      driver_path: driver,
      browser_idle_timeout_ms: 60
    ]

    assert {:ok, _} =
             CloudSession.request(
               :test_hosted,
               "browser.tabs",
               %{},
               1_000,
               base ++ [session_id: "one"]
             )

    assert {:ok, _} =
             CloudSession.request(
               :test_hosted,
               "browser.tabs",
               %{},
               1_000,
               base ++ [session_id: "two"]
             )

    assert_received {:created, "one"}
    assert_received {:created, "two"}

    assert eventually(fn -> CloudSession.status(:test_hosted) == [] end)
    assert_received {:closed, "provider-one"}
    assert_received {:closed, "provider-two"}
  end

  defp stop_fake_sessions do
    LemonBrowser.CloudSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn
      {{:test_hosted, _scope}, pid} when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
      _ -> :ok
    end)
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end

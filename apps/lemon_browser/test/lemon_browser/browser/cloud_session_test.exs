defmodule LemonBrowser.CloudSessionTest do
  use ExUnit.Case, async: false

  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

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
      # Mirrors real providers: inline key first, then the configured secret.
      key =
        LemonBrowser.SessionProviders.Helpers.get_value(config, :api_key) ||
          LemonBrowser.SessionProviders.Helpers.secret("TEST_HOSTED_API_KEY")

      send(config.test_pid, {:close_key, id, key})
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

    assert_eventually(fn -> CloudSession.status(:test_hosted) == [] end)
    assert_received {:closed, "provider-one"}
    assert_received {:closed, "provider-two"}
  end

  test "session and driver process state never expose CDP or provider credentials", %{
    driver: driver
  } do
    opts = [
      session_id: "state-scope",
      provider_config: %{test_pid: self(), api_key: "provider-api-secret"},
      driver_path: driver,
      browser_idle_timeout_ms: 5_000
    ]

    assert {:ok, _} = CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, opts)

    scope = %{session_id: "state-scope", browser_profile_id: nil, run_id: nil}
    [{pid, _}] = Registry.lookup(LemonBrowser.CloudSessionRegistry, {:test_hosted, scope})
    {:links, links} = Process.info(pid, :links)
    driver_pid = Enum.find(links, &match?(%{port: port} when is_port(port), safe_state(&1)))
    assert is_pid(driver_pid)

    supervisor = Process.whereis(LemonBrowser.CloudSessionSupervisor)

    for target <- [pid, driver_pid, supervisor],
        secret <- ["credential@", "provider-api-secret"] do
      refute contains_secret?(:sys.get_state(target), secret)
      refute inspect(:sys.get_status(target), limit: :infinity) =~ secret
    end

    # Closing still works with the credential-free retained configuration.
    GenServer.stop(pid, :normal, 1_000)
    assert_received {:closed, "provider-state-scope"}
  end

  test "a driver that cannot start releases the provider session it was created for" do
    opts = [
      session_id: "no-driver",
      provider_config: %{test_pid: self(), api_key: "failed-start-secret"},
      driver_path: "/nonexistent/lemon-driver.js",
      browser_idle_timeout_ms: 5_000
    ]

    assert {:error, reason} = CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, opts)
    assert reason =~ "does not exist"
    assert_received {:created, "no-driver"}
    assert_received {:close_key, "provider-no-driver", "failed-start-secret"}
    assert_received {:closed, "provider-no-driver"}

    scope = %{session_id: "no-driver", browser_profile_id: nil, run_id: nil}
    [{pid, _}] = Registry.lookup(LemonBrowser.CloudSessionRegistry, {:test_hosted, scope})
    state = :sys.get_state(pid)
    assert state.session == nil
    assert state.credential_ref == nil
    assert state.driver == nil

    for target <- [pid, Process.whereis(LemonBrowser.CredentialVault)],
        secret <- ["credential@", "failed-start-secret"] do
      refute contains_secret?(:sys.get_state(target), secret)
    end
  end

  for {label, global} <- [{"absent", nil}, {"different", "global-other-secret"}] do
    test "idle expiry and termination close with the session's inline key (global #{label})", %{
      driver: driver
    } do
      with_env("TEST_HOSTED_API_KEY", unquote(global), fn ->
        base = [
          provider_config: %{test_pid: self(), api_key: "inline-session-secret"},
          driver_path: driver
        ]

        idle = base ++ [session_id: "idle-close", browser_idle_timeout_ms: 60]
        assert {:ok, _} = CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, idle)
        assert_receive {:close_key, "provider-idle-close", "inline-session-secret"}, 2_000

        live = base ++ [session_id: "stop-close", browser_idle_timeout_ms: 5_000]
        assert {:ok, _} = CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, live)
        scope = %{session_id: "stop-close", browser_profile_id: nil, run_id: nil}
        [{pid, _}] = Registry.lookup(LemonBrowser.CloudSessionRegistry, {:test_hosted, scope})

        for target <- [pid, Process.whereis(LemonBrowser.CredentialVault)] do
          refute contains_secret?(:sys.get_state(target), "inline-session-secret")
        end

        GenServer.stop(pid, :normal, 1_000)
        assert_received {:close_key, "provider-stop-close", "inline-session-secret"}
      end)
    end
  end

  test "provider URLs embedding credentials are rejected before any session state", %{
    driver: driver
  } do
    opts = [
      session_id: "userinfo-url",
      provider_config: %{test_pid: self(), base_url: "https://user:url-secret@api.test"},
      driver_path: driver
    ]

    assert {:error, reason} = CloudSession.request(:test_hosted, "browser.tabs", %{}, 1_000, opts)
    assert reason =~ "must not embed credentials"
    refute_received {:created, _}
    assert CloudSession.status(:test_hosted) == []

    supervisor = Process.whereis(LemonBrowser.CloudSessionSupervisor)
    refute contains_secret?(:sys.get_state(supervisor), "url-secret")
  end

  defp with_env(name, value, fun) do
    original = System.get_env(name)
    if value, do: System.put_env(name, value), else: System.delete_env(name)

    try do
      fun.()
    after
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end
  end

  defp safe_state(pid) when is_pid(pid) do
    :sys.get_state(pid, 500)
  catch
    :exit, _ -> nil
  end

  defp safe_state(_port), do: nil

  # Walks the whole term, including closure environments.
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

  defp stop_fake_sessions do
    LemonBrowser.CloudSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn
      {{:test_hosted, _scope}, pid} when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
      _ -> :ok
    end)
  end
end

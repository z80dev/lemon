defmodule LemonBrowser.CamofoxSessionTest do
  use ExUnit.Case, async: false

  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonBrowser.CamofoxSession

  setup do
    test_pid = self()

    http_post = fn url, opts ->
      send(test_pid, {:post, url, opts})

      body = Keyword.fetch!(opts, :json)

      cond do
        String.ends_with?(url, "/tabs") ->
          response(201, %{"tabId" => "tab-secret-1", "url" => body["url"]})

        String.ends_with?(url, "/click") ->
          response(200, %{"url" => Map.get(body, "testRedirect", "https://example.com/next")})

        String.ends_with?(url, "/type") ->
          response(200, %{"url" => "https://example.com/next"})

        String.ends_with?(url, "/navigate") ->
          response(200, %{"url" => body["url"]})

        true ->
          response(200, %{})
      end
    end

    http_get = fn url, opts ->
      send(test_pid, {:get, url, opts})

      cond do
        String.ends_with?(url, "/snapshot") ->
          response(200, %{
            "url" => "https://example.com",
            "title" => "Example",
            "snapshot" => "@e5 button Open account",
            "refsCount" => 1
          })

        String.ends_with?(url, "/screenshot") ->
          {:ok,
           %Req.Response{
             status: 200,
             headers: %{"content-type" => ["image/webp"]},
             body: <<1, 2, 3>>
           }}

        String.ends_with?(url, "/tabs") ->
          response(200, %{
            "tabs" => [
              %{"tabId" => "tab-secret-1", "url" => "https://example.com", "title" => "Example"}
            ]
          })

        true ->
          response(404, %{"error" => "not found"})
      end
    end

    http_delete = fn url, opts ->
      send(test_pid, {:delete, url, opts})
      response(204, "")
    end

    on_exit(&stop_sessions/0)

    session_id = "lemon-session-secret-#{System.unique_integer([:positive])}"

    {:ok,
     opts: [
       session_id: session_id,
       run_id: "run-secret",
       provider_config: %{
         base_url: "http://camofox.test:9377",
         api_key: "camofox-api-secret"
       },
       http_post: http_post,
       http_get: http_get,
       http_delete: http_delete,
       browser_idle_timeout_ms: 5_000
     ]}
  end

  test "requires an exact Lemon session binding before creating remote state", %{opts: opts} do
    assert {:error, {:missing_camofox_browser_binding, :session_id}} =
             CamofoxSession.request("browser.tabs", %{}, 500, Keyword.delete(opts, :session_id))

    refute_received {:get, _, _}
    refute_received {:post, _, _}
  end

  test "navigates, snapshots, clicks refs, types without echoing text, and captures images", %{
    opts: opts
  } do
    assert {:ok,
            %{
              "url" => "https://example.com",
              "title" => "Example",
              "snapshot" => "@e5 button Open account",
              "elementCount" => 1
            }} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    assert_received {:post, "http://camofox.test:9377/tabs", create_opts}
    assert create_opts[:json]["url"] == "https://example.com"
    assert create_opts[:json]["listItemId"] =~ "session_"
    assert create_opts[:json]["userId"] =~ "lemon_"
    assert {"authorization", "Bearer camofox-api-secret"} in create_opts[:headers]

    assert {:ok, %{"success" => true, "clicked" => true}} =
             CamofoxSession.request(
               "browser.click",
               %{"selector" => "@e5"},
               1_000,
               opts
             )

    assert_received {:post, "http://camofox.test:9377/tabs/tab-secret-1/click", click_opts}
    assert click_opts[:json]["ref"] == "e5"

    secret = "typed-secret-that-must-not-be-echoed"

    assert {:ok, typed} =
             CamofoxSession.request(
               "browser.type",
               %{"selector" => "@e5", "text" => secret},
               1_000,
               opts
             )

    assert typed == %{"success" => true, "typed" => true, "url" => "https://example.com/next"}
    refute inspect(typed) =~ secret
    assert_received {:post, "http://camofox.test:9377/tabs/tab-secret-1/type", type_opts}
    assert type_opts[:json]["text"] == secret

    assert {:ok,
            %{"contentType" => "image/webp", "base64" => encoded, "url" => "https://example.com"}} =
             CamofoxSession.request("browser.screenshot", %{}, 1_000, opts)

    assert Base.decode64!(encoded) == <<1, 2, 3>>
  end

  describe "screenshot reads the tab's current URL" do
    defp capture_opts(opts, session, snapshot_body, private?) do
      parent = self()
      base_get = opts[:http_get]

      get = fn url, request_opts ->
        if String.ends_with?(url, "/snapshot") do
          send(parent, {:snapshot_get, url})
          {:ok, %Req.Response{status: 200, headers: %{}, body: snapshot_body.()}}
        else
          if String.ends_with?(url, "/screenshot"), do: send(parent, {:screenshot_get, url})
          base_get.(url, request_opts)
        end
      end

      opts
      |> Keyword.put(:session_id, session)
      |> Keyword.put(:http_get, get)
      |> Keyword.update!(:provider_config, &Map.put(&1, :allow_private_network, private?))
    end

    test "a file: page is refused even with allow_private_network", %{opts: opts} do
      # Navigation recorded a public URL; the tab has since moved to a file: page.
      {:ok, page} = Agent.start_link(fn -> "https://example.com" end)
      body = fn -> %{"url" => Agent.get(page, & &1), "snapshot" => ""} end
      opts = capture_opts(opts, "camofox-file-page", body, true)

      assert {:ok, _} =
               CamofoxSession.request(
                 "browser.navigate",
                 %{"url" => "https://example.com"},
                 1_000,
                 opts
               )

      Agent.update(page, fn _ -> "file:///etc/passwd" end)

      assert {:error, reason} = CamofoxSession.request("browser.screenshot", %{}, 1_000, opts)
      assert reason =~ "allowLocalDocument"
      assert_received {:snapshot_get, _}
      refute_received {:screenshot_get, _}

      assert {:ok, %{"url" => "file:///etc/passwd"}} =
               CamofoxSession.request(
                 "browser.screenshot",
                 %{"allowLocalDocument" => true},
                 1_000,
                 opts
               )
    end

    test "a missing current URL fails closed", %{opts: opts} do
      {:ok, page} = Agent.start_link(fn -> %{"url" => "https://example.com"} end)
      opts = capture_opts(opts, "camofox-no-url", fn -> Agent.get(page, & &1) end, false)

      assert {:ok, _} =
               CamofoxSession.request(
                 "browser.navigate",
                 %{"url" => "https://example.com"},
                 1_000,
                 opts
               )

      Agent.update(page, fn _ -> %{"snapshot" => ""} end)

      assert {:error, reason} = CamofoxSession.request("browser.screenshot", %{}, 1_000, opts)
      assert reason =~ "current URL"
      refute_received {:screenshot_get, _}
    end
  end

  test "blocks private targets before any remote navigation request", %{opts: opts} do
    assert {:error, reason} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "http://127.0.0.1/admin"},
               1_000,
               opts
             )

    assert reason =~ "public"
    refute_received {:post, _, _}
  end

  test "a remote redirect to a private target fails closed for later reads", %{opts: opts} do
    assert {:ok, _} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               opts
             )

    # Replace the session's HTTP function with a targeted click redirect by using a fresh exact scope.
    parent = self()

    redirect_post = fn url, request_opts ->
      send(parent, {:redirect_post, url, request_opts})

      if String.ends_with?(url, "/tabs") do
        response(201, %{"tabId" => "redirect-tab"})
      else
        response(200, %{"url" => "http://127.0.0.1/redirected"})
      end
    end

    redirect_opts =
      opts
      |> Keyword.put(:session_id, "redirect-session")
      |> Keyword.put(:http_post, redirect_post)

    assert {:ok, _} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               redirect_opts
             )

    assert_received {:get, "http://camofox.test:9377/tabs/redirect-tab/snapshot", _}

    assert {:error, redirect_reason} =
             CamofoxSession.request(
               "browser.click",
               %{"selector" => "@e5"},
               1_000,
               redirect_opts
             )

    assert redirect_reason =~ "public"

    assert {:error, read_reason} =
             CamofoxSession.request("browser.snapshot", %{}, 1_000, redirect_opts)

    assert read_reason =~ "public"
    refute_received {:get, "http://camofox.test:9377/tabs/redirect-tab/snapshot", _}
  end

  test "status redacts remote identity and ephemeral sessions are deleted on idle", %{opts: opts} do
    # The idle timer is armed with a long timeout so the status read below
    # cannot race it; the test fires the timer's message itself.
    assert {:ok, _} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               Keyword.put(opts, :browser_idle_timeout_ms, 5_000)
             )

    [status] = CamofoxSession.status()
    rendered = inspect(status)

    assert status.provider == :camofox
    assert status.connected
    refute rendered =~ "lemon-session-secret"
    refute rendered =~ "run-secret"
    refute rendered =~ "tab-secret-1"
    refute rendered =~ "camofox-api-secret"
    refute rendered =~ "camofox.test"

    [pid] = session_pids()
    assert is_integer(Process.read_timer(:sys.get_state(pid).idle_timer))

    send(pid, :idle_timeout)

    assert_eventually(fn -> CamofoxSession.status() == [] end)
    assert_received {:delete, delete_url, _}
    assert delete_url =~ "/sessions/lemon_"
  end

  test "managed persistence does not delete provider state on idle", %{opts: opts} do
    managed_opts =
      opts
      |> Keyword.put(:session_id, "managed-session")
      |> Keyword.put(:browser_idle_timeout_ms, 40)
      |> Keyword.update!(:provider_config, &Map.put(&1, :managed_persistence, true))

    assert {:ok, _} =
             CamofoxSession.request(
               "browser.navigate",
               %{"url" => "https://example.com"},
               1_000,
               managed_opts
             )

    assert_eventually(fn -> CamofoxSession.status() == [] end)
    refute_received {:delete, _, _}
  end

  test "process state and status never expose the Camofox API key", %{opts: opts} do
    assert {:ok, _} = CamofoxSession.request("browser.tabs", %{}, 1_000, opts)

    assert_received {:get, _url, get_opts}
    assert {"authorization", "Bearer camofox-api-secret"} in get_opts[:headers]

    [pid] = session_pids()
    supervisor = Process.whereis(LemonBrowser.CamofoxSessionSupervisor)

    for target <- [pid, supervisor] do
      refute contains_secret?(:sys.get_state(target), "camofox-api-secret")
      refute inspect(:sys.get_status(target), limit: :infinity) =~ "camofox-api-secret"
    end
  end

  test "base URLs embedding credentials are rejected before any session starts", %{opts: opts} do
    opts =
      Keyword.update!(
        opts,
        :provider_config,
        &Map.put(&1, :base_url, "http://camofox:userinfo-secret@camofox.test:9377")
      )

    assert {:error, reason} = CamofoxSession.request("browser.tabs", %{}, 1_000, opts)
    assert reason =~ "must not embed credentials"
    refute reason =~ "userinfo-secret"
    refute CamofoxSession.available?(opts)
    assert session_pids() == []
    refute_received {:get, _, _}
  end

  for {label, global} <- [{"absent", nil}, {"different", "camofox-global-other"}] do
    test "idle cleanup DELETE authenticates with the session's inline key (global #{label})", %{
      opts: opts
    } do
      original = System.get_env("CAMOFOX_API_KEY")

      if unquote(global),
        do: System.put_env("CAMOFOX_API_KEY", unquote(global)),
        else: System.delete_env("CAMOFOX_API_KEY")

      try do
        assert {:ok, _} =
                 CamofoxSession.request(
                   "browser.navigate",
                   %{"url" => "https://example.com"},
                   1_000,
                   Keyword.put(opts, :browser_idle_timeout_ms, 5_000)
                 )

        [pid] = session_pids()

        for target <- [pid, Process.whereis(LemonBrowser.CredentialVault)] do
          refute contains_secret?(:sys.get_state(target), "camofox-api-secret")
        end

        send(pid, :idle_timeout)
        assert_eventually(fn -> CamofoxSession.status() == [] end)
        assert_received {:delete, _url, delete_opts}
        assert {"authorization", "Bearer camofox-api-secret"} in delete_opts[:headers]
      after
        if original,
          do: System.put_env("CAMOFOX_API_KEY", original),
          else: System.delete_env("CAMOFOX_API_KEY")
      end
    end
  end

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

  defp response(status, body), do: {:ok, %Req.Response{status: status, headers: %{}, body: body}}

  defp stop_sessions do
    LemonBrowser.CamofoxSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_scope, pid} ->
      if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)
  end

  defp session_pids do
    LemonBrowser.CamofoxSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {_scope, pid} -> pid end)
  end
end

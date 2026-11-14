defmodule LemonAi.Auth.OmpAuthBrokerTest do
  use ExUnit.Case, async: false

  alias LemonAi.Auth.OmpAuthBroker

  @endpoint %{url: "http://broker.test:8765", token: "broker-bearer"}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    OmpAuthBroker.invalidate_all()
    on_exit(&OmpAuthBroker.invalidate_all/0)
    :ok
  end

  defp opts(extra \\ []),
    do: Keyword.merge([req_options: [plug: {Req.Test, __MODULE__}], watch: false], extra)

  defp now_ms, do: System.system_time(:millisecond)

  defp oauth(id, provider, access, identity, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "provider" => provider,
        "identityKey" => identity,
        "rotatesInMs" => nil,
        "credential" => %{
          "type" => "oauth",
          "access" => access,
          "refresh" => "__remote__",
          "expires" => now_ms() + 3_600_000
        }
      },
      extra
    )
  end

  defp api_key(id, provider, key) do
    %{
      "id" => id,
      "provider" => provider,
      "identityKey" => nil,
      "rotatesInMs" => nil,
      "credential" => %{"type" => "api_key", "key" => key}
    }
  end

  defp serve(credentials, refresh \\ fn _id, _query -> raise "unexpected refresh" end) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:request, conn.method, conn.request_path, conn.query_string, conn.req_headers})

      case {conn.method, conn.request_path} do
        {"GET", "/v1/snapshot"} ->
          Req.Test.json(conn, %{
            "generation" => 7,
            "generatedAt" => now_ms(),
            "serverNowMs" => now_ms(),
            "refresher" => %{
              "enabled" => true,
              "intervalMs" => 60_000,
              "skewMs" => 300_000,
              "nextSweepInMs" => 1_000
            },
            "credentials" => credentials
          })

        {"POST", "/v1/credential/" <> rest} ->
          [id, action] = String.split(rest, "/")

          case action do
            "refresh" ->
              Req.Test.json(conn, %{"entry" => refresh.(String.to_integer(id), conn.query_string)})

            "block" ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              send(owner, {:block, id, Jason.decode!(body)})
              Req.Test.json(conn, %{"ok" => true})
          end
      end
    end)
  end

  test "prefers OAuth over API keys and unblocked accounts over rate-limited ones" do
    blocked = %{
      "blocks" => [
        %{
          "providerKey" => "anthropic",
          "blockScope" => "chat",
          "blockedUntilMs" => now_ms() + 60_000
        }
      ]
    }

    serve([
      api_key(1, "anthropic", "sk-ant-api"),
      oauth(2, "anthropic", "sk-ant-oat-blocked", "email:a@example.com", blocked),
      oauth(3, "anthropic", "sk-ant-oat-free", "email:b@example.com"),
      api_key(4, "openrouter", "sk-or")
    ])

    assert {:ok, entry} = OmpAuthBroker.credential(@endpoint, "anthropic", opts())
    assert entry.id == 3
    assert OmpAuthBroker.secret(entry) == "sk-ant-oat-free"

    assert_receive {:request, "GET", "/v1/snapshot", _, headers}
    assert {"authorization", "Bearer broker-bearer"} in headers
    assert {"omp-auth-broker-capabilities", "codex-meter-block-scopes"} in headers

    # The snapshot is cached: later resolutions do not hit the broker again.
    assert {:ok, %{id: 4}} = OmpAuthBroker.credential(@endpoint, "openrouter", opts())
    refute_receive {:request, _, _, _, _}
  end

  test "an account selector restricts to that OAuth identity and never uses API keys" do
    serve([
      api_key(1, "anthropic", "sk-ant-api"),
      oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com"),
      oauth(3, "anthropic", "sk-ant-oat-b", "email:b@example.com")
    ])

    assert {:ok, %{id: 2}} =
             OmpAuthBroker.credential(
               @endpoint,
               "anthropic",
               opts() ++ [account: "email:a@example.com"]
             )

    assert {:error, :no_credential} =
             OmpAuthBroker.credential(@endpoint, "anthropic", opts() ++ [account: "email:z@x"])
  end

  test "an expiring OAuth token is refreshed by the broker and the cache adopts it" do
    expiring = %{
      "credential" => %{
        "type" => "oauth",
        "access" => "old-access",
        "refresh" => "__remote__",
        "expires" => now_ms() + 5_000
      }
    }

    serve([oauth(9, "openai-codex", "old-access", "account:x", expiring)], fn 9, query ->
      assert query == ""

      %{
        "id" => 9,
        "provider" => "openai-codex",
        "identityKey" => "account:x",
        "credential" => %{
          "type" => "oauth",
          "access" => "new-access",
          "refresh" => "__remote__",
          "expires" => now_ms() + 3_600_000
        }
      }
    end)

    assert {:ok, entry} = OmpAuthBroker.credential(@endpoint, "openai-codex", opts())
    assert OmpAuthBroker.secret(entry) == "new-access"
    assert_receive {:request, "GET", "/v1/snapshot", _, _}
    assert_receive {:request, "POST", "/v1/credential/9/refresh", "", _}

    assert {:ok, cached} = OmpAuthBroker.credential(@endpoint, "openai-codex", opts())
    assert OmpAuthBroker.secret(cached) == "new-access"
    refute_receive {:request, _, _, _, _}
  end

  test "auth recovery refreshes with the recovery reason" do
    serve([oauth(5, "kimi-code", "rejected", "account:k")], fn 5, query ->
      assert query == "reason=auth-recovery"
      oauth(5, "kimi-code", "recovered", "account:k") |> Map.delete("rotatesInMs")
    end)

    assert {:ok, entry} = OmpAuthBroker.refresh(@endpoint, 5, opts() ++ [reason: "auth-recovery"])
    assert OmpAuthBroker.secret(entry) == "recovered"
  end

  test "broker failures are bare atoms without response content" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
    end)

    assert {:error, :broker_unauthorized} =
             OmpAuthBroker.credential(@endpoint, "anthropic", opts())

    assert {:error, :missing_broker_token} =
             OmpAuthBroker.credential(%{@endpoint | token: ""}, "anthropic", opts())

    assert {:error, :invalid_broker_url} =
             OmpAuthBroker.credential(%{@endpoint | url: "http://user:pw@host"}, "x", opts())
  end

  test "credentials/3 lists every account in selection order and credential/3 accepts an id" do
    serve([
      api_key(1, "anthropic", "sk-ant-api"),
      oauth(3, "anthropic", "sk-ant-oat-b", "email:b@example.com"),
      oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com"),
      api_key(4, "openrouter", "sk-or")
    ])

    assert {:ok, entries} = OmpAuthBroker.credentials(@endpoint, "anthropic", opts())
    assert Enum.map(entries, & &1.id) == [2, 3, 1]
    assert_receive {:request, "GET", "/v1/snapshot", _, _}

    assert Enum.map(entries, &OmpAuthBroker.provider_key/1) ==
             ["anthropic:oauth", "anthropic:oauth", "anthropic:api_key"]

    assert {:ok, [%{id: 2}]} =
             OmpAuthBroker.credentials(
               @endpoint,
               "anthropic",
               opts() ++ [account: "email:a@example.com"]
             )

    assert {:ok, []} = OmpAuthBroker.credentials(@endpoint, "nothing", opts())

    assert {:ok, %{id: 1} = api} =
             OmpAuthBroker.credential(@endpoint, "anthropic", opts() ++ [id: 1])

    assert OmpAuthBroker.secret(api) == "sk-ant-api"
    assert {:ok, %{id: 3}} = OmpAuthBroker.credential(@endpoint, "anthropic", opts() ++ [id: 3])

    # The id must belong to the requested provider.
    assert {:error, :no_credential} =
             OmpAuthBroker.credential(@endpoint, "anthropic", opts() ++ [id: 4])

    assert {:error, :no_credential} =
             OmpAuthBroker.credential(@endpoint, "anthropic", opts() ++ [id: 99])

    # One snapshot served all of the above.
    refute_receive {:request, _, _, _, _}
  end

  test "block/5 reports a catch-all rate limit and the cached snapshot orders the entry last" do
    serve([
      oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com"),
      oauth(3, "anthropic", "sk-ant-oat-b", "email:b@example.com"),
      oauth(5, "anthropic", "sk-ant-oat-c", "email:c@example.com")
    ])

    assert {:ok, entries} = OmpAuthBroker.credentials(@endpoint, "anthropic", opts())
    assert Enum.map(entries, & &1.id) == [2, 3, 5]
    assert_receive {:request, "GET", "/v1/snapshot", _, _}

    until = now_ms() + 60_000
    assert :ok = OmpAuthBroker.block(@endpoint, 2, "anthropic:oauth", until, opts())

    assert_receive {:request, "POST", "/v1/credential/2/block", "", headers}
    assert {"authorization", "Bearer broker-bearer"} in headers

    assert_receive {:block, "2", body}

    assert body == %{
             "providerKey" => "anthropic:oauth",
             "blockScope" => "",
             "blockedUntilMs" => until
           }

    assert {:ok, entries} = OmpAuthBroker.credentials(@endpoint, "anthropic", opts())
    assert Enum.map(entries, & &1.id) == [3, 5, 2]

    assert [%{provider_key: "anthropic:oauth", scope: "", blocked_until_ms: ^until}] =
             List.last(entries).blocks

    # A shorter block for the same key and scope never shortens the cached one.
    assert :ok = OmpAuthBroker.block(@endpoint, 2, "anthropic:oauth", until - 30_000, opts())
    assert_receive {:block, "2", _}
    assert {:ok, entries} = OmpAuthBroker.credentials(@endpoint, "anthropic", opts())

    assert [%{blocked_until_ms: ^until}] = List.last(entries).blocks

    # Neither block triggered another snapshot fetch.
    refute_receive {:request, "GET", _, _, _}
  end

  test "block/5 reports bare atoms for broker failures" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "unknown credential"})
    end)

    assert {:error, :broker_not_found} =
             OmpAuthBroker.block(@endpoint, 42, "anthropic:oauth", now_ms() + 1_000, opts())
  end

  describe "snapshot watcher" do
    @table :lemon_ai_omp_auth_broker

    defp watch_opts, do: opts(watch: true, watch_wait_ms: 50)

    defp cache_key, do: {@endpoint.url, :crypto.hash(:sha256, @endpoint.token)}

    defp snapshot_body(generation, credentials) do
      %{
        "generation" => generation,
        "generatedAt" => now_ms(),
        "serverNowMs" => now_ms(),
        "credentials" => credentials
      }
    end

    # The initial snapshot answers immediately. A long-poll is reported to the
    # test (`{:poll, watcher_pid, query, if_none_match}`) and held until the
    # test replies with `{:poll_reply, 304}`, `{:poll_reply, status}` or
    # `{:poll_reply, generation, credentials}`.
    defp serve_watched(generation, credentials) do
      owner = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.query_string do
          "" ->
            send(owner, :snapshot_get)
            Req.Test.json(conn, snapshot_body(generation, credentials))

          query ->
            send(owner, {:poll, self(), query, Plug.Conn.get_req_header(conn, "if-none-match")})

            receive do
              {:poll_reply, status} when is_integer(status) ->
                Plug.Conn.send_resp(conn, status, "")

              {:poll_reply, next_generation, next_credentials} ->
                Req.Test.json(conn, snapshot_body(next_generation, next_credentials))
            after
              500 -> Plug.Conn.send_resp(conn, 304, "")
            end
        end
      end)
    end

    defp backdate_cache do
      old = System.monotonic_time(:millisecond) - 60_000
      assert :ets.update_element(@table, cache_key(), {3, old})
      old
    end

    defp wait_until(fun, attempts \\ 100) do
      cond do
        fun.() -> :ok
        attempts == 0 -> flunk("condition not reached")
        true -> Process.sleep(20) && wait_until(fun, attempts - 1)
      end
    end

    test "a long-poll 200 replaces the cache without TTL expiry and sends If-None-Match" do
      serve_watched(7, [oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com")])

      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      assert_receive :snapshot_get
      assert_receive {:poll, watcher, "wait=50", [~s("7")]}

      # Older than the TTL, yet served: the healthy watcher keeps it current.
      backdate_cache()
      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())

      send(
        watcher,
        {:poll_reply, 8,
         [
           oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com"),
           oauth(3, "anthropic", "sk-ant-oat-b", "email:b@example.com")
         ]}
      )

      # The next poll carries the new generation: the snapshot was stored first.
      assert_receive {:poll, ^watcher, "wait=50", [~s("8")]}
      assert {:ok, entries} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      assert Enum.map(entries, & &1.id) == [2, 3]

      refute_receive :snapshot_get
    end

    test "a 304 keeps the cached snapshot current" do
      serve_watched(7, [oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com")])

      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      assert_receive :snapshot_get
      assert_receive {:poll, watcher, _, [~s("7")]}

      old = backdate_cache()
      send(watcher, {:poll_reply, 304})

      assert_receive {:poll, ^watcher, _, [~s("7")]}
      assert [{_, {:ok, %{generation: 7}}, stored_at}] = :ets.lookup(@table, cache_key())
      assert stored_at > old

      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      refute_receive :snapshot_get
    end

    test "a failing watcher stops and the cache falls back to its TTL" do
      serve_watched(7, [oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com")])

      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      assert_receive :snapshot_get
      assert_receive {:poll, watcher, _, _}

      ref = Process.monitor(watcher)
      send(watcher, {:poll_reply, 401})
      assert_receive {:DOWN, ^ref, :process, ^watcher, _}
      assert :ets.lookup(@table, {:watcher, cache_key()}) == []

      # Without a watcher an expired snapshot is fetched again (and a new
      # watcher starts).
      backdate_cache()
      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", watch_opts())
      assert_receive :snapshot_get
      assert_receive {:poll, new_watcher, _, [~s("7")]}
      assert new_watcher != watcher
    end

    test "an unread endpoint's watcher stops after the idle period" do
      serve_watched(7, [oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com")])

      assert {:ok, [%{id: 2}]} =
               OmpAuthBroker.credentials(
                 @endpoint,
                 "anthropic",
                 watch_opts() ++ [watch_idle_ms: 1]
               )

      assert_receive :snapshot_get
      wait_until(fn -> :ets.lookup(@table, {:watcher, cache_key()}) == [] end)
    end

    test "watching can be disabled per call" do
      serve([oauth(2, "anthropic", "sk-ant-oat-a", "email:a@example.com")])

      assert {:ok, [%{id: 2}]} = OmpAuthBroker.credentials(@endpoint, "anthropic", opts())
      assert :ets.lookup(@table, {:watcher, cache_key()}) == []
    end
  end
end

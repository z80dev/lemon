defmodule LemonAi.Auth.OAuthFlowTest do
  use ExUnit.Case, async: true

  alias LemonAi.Auth.OAuthFlow

  defp poll(results, opts) do
    {:ok, queue} = Agent.start_link(fn -> results end)
    test_pid = self()

    OAuthFlow.poll_device_token(
      fn ->
        Agent.get_and_update(queue, fn
          [n | r] -> {n, r}
          [] -> {:pending, []}
        end)
      end,
      Keyword.put(opts, :sleep, &send(test_pid, {:slept, &1}))
    )
  end

  defp waited(acc \\ 0) do
    receive do
      {:slept, ms} -> waited(acc + ms)
    after
      0 -> acc
    end
  end

  test "stops polling when the device code expires instead of polling forever" do
    assert {:error, :device_flow_timed_out} = poll([], interval_s: 5, expires_in_s: 30)
    assert waited() <= 30_000
  end

  test "slow_down widens the interval and names clock drift when the code then expires" do
    assert {:error, :device_flow_timed_out_after_slow_down} =
             poll([:slow_down], interval_s: 5, expires_in_s: 60)

    assert_received {:slept, 10_000}
  end

  test "only allowlisted OAuth errors survive the public error boundary" do
    assert OAuthFlow.http_error(400, %{"error" => "invalid_client"}) ==
             {:http_error, 400, "invalid_client"}

    for body <- [
          %{"error" => "access-token secret-code user@example.com"},
          %{"error" => %{"access_token" => "secret"}},
          %{"error" => "invalid_grant\nsecret", "error_description" => "secret"},
          "secret response"
        ] do
      assert OAuthFlow.http_error(400, body) == {:http_error, 400}
    end
  end

  test "token requests never follow redirects carrying grant credentials" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "auth.x.ai"

      conn
      |> Plug.Conn.put_resp_header("location", "https://attacker.test/token")
      |> Plug.Conn.send_resp(307, "")
    end)

    assert {:ok, %{status: 307}} =
             OAuthFlow.request(
               "https://auth.x.ai/token",
               [form: %{"refresh_token" => "secret"}],
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "malformed and already-expired device responses fail without exposing their body" do
    for body <- ["secret", [], %{"access_token" => "secret"}] do
      assert {:error, :invalid_device_authorization_response} =
               OAuthFlow.parse_device_response(%{status: 200, body: body})
    end

    for expiry <- [0, -1, "bad"] do
      body = %{
        "device_code" => "d",
        "user_code" => "u",
        "verification_uri" => "https://example.test/device",
        "expires_in" => expiry
      }

      assert {:error, :invalid_device_authorization_response} =
               OAuthFlow.parse_device_response(%{status: 200, body: body})
    end
  end

  test "request duration counts against device expiry" do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    now = fn -> Agent.get(clock, & &1) end

    assert {:error, :device_flow_timed_out} =
             OAuthFlow.poll_device_token(
               fn ->
                 Agent.update(clock, &(&1 + 31_000))
                 :pending
               end,
               interval_s: 5,
               expires_in_s: 30,
               now: now,
               sleep: fn _ -> flunk("must not sleep or poll after expiry") end
             )
  end

  test "callback time and oversleep cannot extend a device deadline" do
    assert {:error, :device_flow_timed_out} =
             OAuthFlow.poll_device_token(fn -> flunk("expired before polling") end,
               deadline_ms: 10,
               now: fn -> 11 end
             )

    {:ok, clock} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    assert {:error, :device_flow_timed_out} =
             OAuthFlow.poll_device_token(
               fn ->
                 send(test_pid, :polled)
                 :pending
               end,
               interval_s: 1,
               expires_in_s: 3,
               now: fn -> Agent.get(clock, & &1) end,
               sleep: fn _ -> Agent.update(clock, fn _ -> 4_000 end) end
             )

    assert_received :polled
    refute_received :polled
  end

  test "serialized refreshes reload and persist only the requested storage identity" do
    stale = %{"access_token" => "old", "refresh_token" => "old-refresh", "expires_at_ms" => 0}

    {:ok, store} =
      Agent.start_link(fn -> %{encoded: Jason.encode!(stale), revision: make_ref()} end)

    test_pid = self()
    name = "custom-profile-secret"

    spec = %{
      lock: {__MODULE__, make_ref()},
      skew_ms: 0,
      decode: fn value -> {:ok, Jason.decode!(value)} end,
      encode: &Jason.encode!/1,
      refresh: fn secret ->
        assert secret["refresh_token"] == "old-refresh"
        send(test_pid, {:refreshing, self()})

        receive do
          :release -> :ok
        end

        {:ok,
         Map.merge(secret, %{
           "access_token" => "new",
           "refresh_token" => "rotated",
           "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
         })}
      end
    }

    opts = [
      reload_secret: fn ^name -> Agent.get(store, &{:ok, &1.encoded, &1.revision}) end,
      persist_secret: fn ^name, value, expected ->
        Agent.get_and_update(store, fn current ->
          if current.revision == expected,
            do: {:ok, %{encoded: value, revision: make_ref()}},
            else: {{:error, :stale_revision}, current}
        end)
      end
    ]

    first = Task.async(fn -> OAuthFlow.ensure_fresh(name, stale, opts, spec) end)
    assert_receive {:refreshing, holder}
    second = Task.async(fn -> OAuthFlow.ensure_fresh(name, stale, opts, spec) end)
    send(holder, :release)

    assert {:ok, %{"access_token" => "new"}} = Task.await(first)
    assert {:ok, %{"access_token" => "new"}} = Task.await(second)
    refute_received {:refreshing, _}
    assert Jason.decode!(Agent.get(store, & &1.encoded))["refresh_token"] == "rotated"
  end

  test "a removed or replaced secret never refreshes its stale credential" do
    secret = %{"access_token" => "old", "refresh_token" => "old-refresh", "expires_at_ms" => 0}

    spec = %{
      lock: {__MODULE__, make_ref()},
      skew_ms: 0,
      decode: fn _ -> :not_oauth end,
      encode: &Jason.encode!/1,
      refresh: fn _ -> flunk("must not resurrect stale login") end
    }

    for {loaded, reason} <- [
          {{:error, :not_found}, :oauth_secret_missing},
          {{:ok, "plain-key"}, :oauth_secret_replaced}
        ] do
      assert {:error, ^reason} =
               OAuthFlow.ensure_fresh("custom", secret, [reload_secret: fn _ -> loaded end], spec)
    end
  end

  test "storage failures stay distinct from absent credentials and never request refresh" do
    secret = %{"access_token" => "old", "refresh_token" => "refresh", "expires_at_ms" => 0}

    spec = %{
      lock: {__MODULE__, make_ref()},
      skew_ms: 0,
      decode: &Jason.decode/1,
      encode: &Jason.encode!/1,
      refresh: fn _ -> flunk("storage failure cannot authorize refresh") end
    }

    for reload <- [
          fn _ -> {:error, :store_unavailable} end,
          fn _ -> raise "private storage failure" end,
          fn _ -> exit(:private_storage_failure) end
        ] do
      assert {:error, :oauth_secret_reload_failed} =
               OAuthFlow.ensure_fresh("custom", secret, [reload_secret: reload], spec)
    end
  end

  test "only acknowledged conditional persistence makes a rotated credential usable" do
    secret = %{"access_token" => "old", "refresh_token" => "refresh", "expires_at_ms" => 0}
    encoded = Jason.encode!(secret)
    revision = make_ref()
    fresh = Map.merge(secret, %{"access_token" => "new", "expires_at_ms" => nil})

    spec = %{
      lock: {__MODULE__, make_ref()},
      skew_ms: 0,
      decode: &Jason.decode/1,
      encode: &Jason.encode!/1,
      refresh: fn _ -> {:ok, fresh} end
    }

    for {acknowledgement, result} <- [
          {:ok, {:ok, fresh}},
          {{:ok, %{}}, {:ok, fresh}},
          {{:error, :stale_revision}, {:error, :oauth_secret_changed}},
          {{:error, :store_unavailable}, {:error, :oauth_secret_persistence_failed}},
          {nil, {:error, :oauth_secret_persistence_failed}},
          {false, {:error, :oauth_secret_persistence_failed}},
          {:unexpected, {:error, :oauth_secret_persistence_failed}}
        ] do
      opts = [
        reload_secret: fn "conditional" -> {:ok, encoded, revision} end,
        persist_secret: fn "conditional", value, expected ->
          assert expected == revision
          assert Jason.decode!(value) == fresh
          acknowledgement
        end
      ]

      assert OAuthFlow.ensure_fresh("conditional", secret, opts, spec) == result
    end
  end

  test "durable refresh requires an explicit incarnation snapshot before the request" do
    secret = %{"access_token" => "old", "refresh_token" => "refresh", "expires_at_ms" => 0}
    encoded = Jason.encode!(secret)

    spec = %{
      lock: {__MODULE__, make_ref()},
      skew_ms: 0,
      decode: &Jason.decode/1,
      encode: &Jason.encode!/1,
      refresh: fn _ -> flunk("unbound refresh cannot start a token request") end
    }

    for reload <- [
          nil,
          :malformed,
          fn _ -> {:ok, encoded} end,
          fn _ -> {:ok, encoded, nil} end
        ] do
      assert {:error, :oauth_secret_reload_failed} =
               OAuthFlow.ensure_fresh(
                 "conditional",
                 secret,
                 [
                   reload_secret: reload,
                   persist_secret: fn _, _, _ -> flunk("unbound write cannot run") end
                 ],
                 spec
               )
    end
  end
end

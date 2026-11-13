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

  defp opts, do: [req_options: [plug: {Req.Test, __MODULE__}]]

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
          [id, "refresh"] = String.split(rest, "/")
          Req.Test.json(conn, %{"entry" => refresh.(String.to_integer(id), conn.query_string)})
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
end

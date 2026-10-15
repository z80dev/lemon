defmodule LemonChannels.Doctor.LiveChecksTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Doctor.LiveChecks, as: Channels
  alias LemonCore.Doctor.{LiveChecks, Report}

  test "Telegram getMe and Discord identity GET return only bot usernames" do
    parent = self()

    opts = [
      config: %{
        gateway: %{
          enable_telegram: true,
          enable_discord: true,
          telegram: %{bot_token: "123:fake-token"},
          discord: %{bot_token: "discord-token"}
        }
      },
      http_get: fn :get, {url, headers}, _, _ ->
        url = to_string(url)
        send(parent, {:request, url})

        body =
          if String.ends_with?(url, "/getMe") do
            assert headers == []

            Jason.encode!(%{
              ok: true,
              result: %{username: "lemon_test_bot", first_name: "private"}
            })
          else
            assert url == "https://discord.com/api/v10/users/@me"
            assert {~c"authorization", ~c"Bot discord-token"} in headers
            Jason.encode!(%{username: "lemon_discord", email: "private@example.invalid"})
          end

        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], body}}
      end
    ]

    results = opts |> Channels.jobs() |> LiveChecks.run()
    assert Enum.count(results, &(&1.status == :pass)) == 2
    assert Enum.any?(results, &(&1.message =~ "@lemon_test_bot"))
    assert Enum.any?(results, &(&1.message =~ "@lemon_discord"))
    assert_received {:request, "https://api.telegram.org/bot123:fake-token/getMe"}
    assert_received {:request, "https://discord.com/api/v10/users/@me"}
    json = results |> Report.from_checks() |> Report.to_json()
    refute json =~ "fake-token"
    refute json =~ "discord-token"
    refute json =~ "private"
  end

  for {response, message} <- [
        {{:ok, {{~c"HTTP/1.1", 403, ~c"No"}, [], "token=fake-token"}}, "rejected"},
        {{:error, :timeout}, "timed out"},
        {{:error, :econnrefused}, "Could not reach"},
        {{:ok, {{~c"HTTP/1.1", 502, ~c"No"}, [], "fake-token"}}, "HTTP 502"},
        {{:ok,
          {{~c"HTTP/1.1", 200, ~c"OK"}, [], "{\"ok\":false,\"description\":\"fake-token\"}"}},
         "Unexpected"}
      ] do
    test "channel failure #{message} is bounded and safe" do
      opts = [
        config: %{gateway: %{enable_telegram: true, telegram: %{bot_token: "fake-token"}}},
        http_get: fn :get, _, _, _ -> unquote(Macro.escape(response)) end
      ]

      check =
        opts
        |> Channels.jobs()
        |> LiveChecks.run()
        |> Enum.find(&(&1.name == "channels.telegram.live"))

      assert check.status == :fail
      assert check.message =~ unquote(message)
      refute inspect(check) =~ "fake-token"
    end
  end

  test "disabled channels and other channels are skipped without HTTP" do
    opts = [config: %{gateway: %{}}, http_get: fn _, _, _, _ -> flunk("no HTTP") end]
    results = opts |> Channels.jobs() |> LiveChecks.run()
    assert Enum.all?(results, &(&1.status == :skip))
    assert Enum.any?(results, &(&1.message =~ "Other channels skipped"))
  end

  test "missing Telegram credential is skipped without HTTP" do
    opts = [
      config: %{gateway: %{enable_telegram: true, telegram: %{}}},
      http_get: fn _, _, _, _ -> flunk("no HTTP") end
    ]

    results = opts |> Channels.jobs() |> LiveChecks.run()
    check = Enum.find(results, &(&1.name == "channels.telegram.live"))
    assert check.status == :skip
    assert check.message =~ "no usable bot credential"
  end

  test "a reflected bot token is redacted even when it resembles a username" do
    opts = [
      config: %{gateway: %{enable_discord: true, discord: %{bot_token: "fake.secret.value"}}},
      http_get: fn :get, _, _, _ ->
        {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~s({"username":"fake.secret.value"})}}
      end
    ]

    check =
      opts
      |> Channels.jobs()
      |> LiveChecks.run()
      |> Enum.find(&(&1.name == "channels.discord.live"))

    assert check.status == :pass
    assert check.message =~ "[REDACTED]"
    refute check.message =~ "fake.secret.value"
  end
end

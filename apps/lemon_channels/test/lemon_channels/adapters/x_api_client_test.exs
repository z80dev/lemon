defmodule LemonChannels.Adapters.XAPI.ClientTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.XAPI
  alias LemonChannels.Adapters.XAPI.Client
  alias LemonChannels.Adapters.XAPI.TokenManager

  @x_api_env_keys [
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_TOKEN_EXPIRES_AT",
    "X_DEFAULT_ACCOUNT_ID",
    "X_DEFAULT_ACCOUNT_USERNAME"
  ]

  setup do
    previous_req_defaults = Req.default_options()
    previous_config = Application.get_env(:lemon_channels, XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)

    previous_env =
      Enum.into(@x_api_env_keys, %{}, fn key ->
        {key, System.get_env(key)}
      end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Enum.each(@x_api_env_keys, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:lemon_channels, XAPI)
      else
        Application.put_env(:lemon_channels, XAPI, previous_config)
      end

      if is_nil(previous_use_secrets) do
        Application.delete_env(:lemon_channels, :x_api_use_secrets)
      else
        Application.put_env(:lemon_channels, :x_api_use_secrets, previous_use_secrets)
      end

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Req.default_options(previous_req_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "get_mentions uses numeric default account id directly" do
    configure_oauth2(default_account_id: "2022351619589873664")
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert {:ok, %{"data" => []}} = Client.get_mentions(limit: 1)

    assert_receive {:req, "/2/users/2022351619589873664/mentions", query}
    assert query =~ "max_results=5"

    refute_received {:req, "/2/users/me"}
    refute_received {:req, "/2/users/me/mentions"}
  end

  test "get_mentions resolves user id via users/me when default account id is not set" do
    configure_oauth2()
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/2/users/me" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"data" => %{"id" => "2022351619589873664"}})
          )

        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert {:ok, %{"data" => []}} = Client.get_mentions(limit: 10)
    assert_receive {:req, "/2/users/me", _}

    assert_receive {:req, "/2/users/2022351619589873664/mentions", query}
    assert query =~ "max_results=10"

    refute_received {:req, "/2/users/me/mentions"}
  end

  test "get_mentions resolves username default account id to numeric id first" do
    configure_oauth2(default_account_id: "samplebot")
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/2/users/by/username/samplebot" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"data" => %{"id" => "2022351619589873664"}})
          )

        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert {:ok, %{"data" => []}} = Client.get_mentions(limit: 7)
    assert_receive {:req, "/2/users/by/username/samplebot", _}

    assert_receive {:req, "/2/users/2022351619589873664/mentions", query}
    assert query =~ "max_results=7"

    refute_received {:req, "/2/users/me"}
    refute_received {:req, "/2/users/me/mentions"}
  end

  test "get_mentions resolves default_account_username when account id is not set" do
    configure_oauth2(default_account_username: "configured_handle")
    start_token_manager!()
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.request_path, conn.query_string})

      case conn.request_path do
        "/2/users/by/username/configured_handle" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(
            200,
            Jason.encode!(%{"data" => %{"id" => "2022351619589873664"}})
          )

        "/2/users/2022351619589873664/mentions" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => []}))

        unexpected ->
          flunk("unexpected request path: #{unexpected}")
      end
    end)

    assert {:ok, %{"data" => []}} = Client.get_mentions(limit: 6)
    assert_receive {:req, "/2/users/by/username/configured_handle", _}

    assert_receive {:req, "/2/users/2022351619589873664/mentions", query}
    assert query =~ "max_results=6"

    refute_received {:req, "/2/users/me"}
    refute_received {:req, "/2/users/me/mentions"}
  end

  defp configure_oauth2(opts \\ []) do
    now = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    config = [
      client_id: "test-client-id",
      client_secret: "test-client-secret",
      access_token: "test-access-token",
      refresh_token: "test-refresh-token",
      token_expires_at: now
    ]

    config =
      [:default_account_id, :default_account_username]
      |> Enum.reduce(config, fn key, acc ->
        case Keyword.fetch(opts, key) do
          {:ok, value} -> Keyword.put(acc, key, value)
          :error -> acc
        end
      end)

    Application.put_env(:lemon_channels, XAPI, config)
  end

  defp start_token_manager! do
    case Process.whereis(TokenManager) do
      pid when is_pid(pid) ->
        pid

      _ ->
        case start_supervised({TokenManager, []}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end

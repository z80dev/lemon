defmodule LemonChannels.Adapters.XAPI.TokenManagerTest.SecretSink do
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def set(name, value, _opts \\ []) do
    Agent.update(__MODULE__, &Map.put(&1, name, value))
    {:ok, %{name: name}}
  end

  def values do
    Agent.get(__MODULE__, & &1)
  end
end

defmodule LemonChannels.Adapters.XAPI.TokenManagerTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.XAPI
  alias LemonChannels.Adapters.XAPI.TokenManager
  alias LemonChannels.Adapters.XAPI.TokenManagerTest.SecretSink
  @x_token_env_vars ~w(X_API_ACCESS_TOKEN X_API_REFRESH_TOKEN X_API_TOKEN_EXPIRES_AT)

  setup do
    previous_req_defaults = Req.default_options()
    previous_config = Application.get_env(:lemon_channels, XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)
    previous_secrets_module = Application.get_env(:lemon_channels, :x_api_secrets_module)
    previous_env = Map.new(@x_token_env_vars, fn key -> {key, System.get_env(key)} end)

    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Application.delete_env(:lemon_channels, :x_api_secrets_module)
    Enum.each(@x_token_env_vars, &System.delete_env/1)

    start_supervised!(SecretSink)

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

      if is_nil(previous_secrets_module) do
        Application.delete_env(:lemon_channels, :x_api_secrets_module)
      else
        Application.put_env(:lemon_channels, :x_api_secrets_module, previous_secrets_module)
      end

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)

      Req.default_options(previous_req_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "refresh persists rotated tokens to app config and secrets backend" do
    configure_oauth2_tokens(
      access_token: "old-access",
      refresh_token: "old-refresh",
      token_expires_at: DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
    )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/2/oauth2/token"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "new-access",
          "refresh_token" => "new-refresh",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    manager_name = token_manager_name()
    start_supervised!({TokenManager, [name: manager_name, secrets_module: SecretSink]})

    assert {:ok, "new-access"} = TokenManager.get_access_token(manager_name)

    persisted = SecretSink.values()
    assert persisted["X_API_ACCESS_TOKEN"] == "new-access"
    assert persisted["X_API_REFRESH_TOKEN"] == "new-refresh"
    assert is_binary(persisted["X_API_TOKEN_EXPIRES_AT"])

    app_config = Application.get_env(:lemon_channels, XAPI, [])
    assert app_config[:access_token] == "new-access"
    assert app_config[:refresh_token] == "new-refresh"
    assert is_binary(app_config[:token_expires_at])
  end

  test "persist_tokens/2 stores tokens even when manager process is not running" do
    configure_oauth2_tokens(
      access_token: "initial-access",
      refresh_token: "initial-refresh",
      token_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    )

    expires_at = DateTime.utc_now() |> DateTime.add(1800, :second)

    assert :ok =
             TokenManager.persist_tokens(
               %{
                 access_token: "direct-access",
                 refresh_token: "direct-refresh",
                 expires_at: expires_at
               },
               secrets_module: SecretSink
             )

    persisted = SecretSink.values()
    assert persisted["X_API_ACCESS_TOKEN"] == "direct-access"
    assert persisted["X_API_REFRESH_TOKEN"] == "direct-refresh"
    assert persisted["X_API_TOKEN_EXPIRES_AT"] == DateTime.to_iso8601(expires_at)

    app_config = Application.get_env(:lemon_channels, XAPI, [])
    assert app_config[:access_token] == "direct-access"
    assert app_config[:refresh_token] == "direct-refresh"
    assert app_config[:token_expires_at] == DateTime.to_iso8601(expires_at)
  end

  test "refresh persists rotated tokens to configured secrets module by default" do
    Application.put_env(:lemon_channels, :x_api_secrets_module, SecretSink)

    configure_oauth2_tokens(
      access_token: "old-access",
      refresh_token: "old-refresh",
      token_expires_at: DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
    )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/2/oauth2/token"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "access_token" => "new-access-default",
          "refresh_token" => "new-refresh-default",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    manager_name = token_manager_name()
    start_supervised!({TokenManager, [name: manager_name]})

    assert {:ok, "new-access-default"} = TokenManager.get_access_token(manager_name)

    persisted = SecretSink.values()
    assert persisted["X_API_ACCESS_TOKEN"] == "new-access-default"
    assert persisted["X_API_REFRESH_TOKEN"] == "new-refresh-default"
    assert is_binary(persisted["X_API_TOKEN_EXPIRES_AT"])
  end

  test "persist_tokens/2 uses configured secrets module when opts are omitted" do
    Application.put_env(:lemon_channels, :x_api_secrets_module, SecretSink)

    configure_oauth2_tokens(
      access_token: "initial-access",
      refresh_token: "initial-refresh",
      token_expires_at: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
    )

    expires_at = DateTime.utc_now() |> DateTime.add(1800, :second)

    assert :ok =
             TokenManager.persist_tokens(%{
               access_token: "direct-access-default",
               refresh_token: "direct-refresh-default",
               expires_at: expires_at
             })

    persisted = SecretSink.values()
    assert persisted["X_API_ACCESS_TOKEN"] == "direct-access-default"
    assert persisted["X_API_REFRESH_TOKEN"] == "direct-refresh-default"
    assert persisted["X_API_TOKEN_EXPIRES_AT"] == DateTime.to_iso8601(expires_at)
  end

  defp configure_oauth2_tokens(config) do
    base = [
      client_id: "test-client-id",
      client_secret: "test-client-secret"
    ]

    Application.put_env(:lemon_channels, XAPI, Keyword.merge(base, config))
  end

  defp token_manager_name do
    {:global, {:x_api_token_manager_test, self(), System.unique_integer([:positive])}}
  end
end

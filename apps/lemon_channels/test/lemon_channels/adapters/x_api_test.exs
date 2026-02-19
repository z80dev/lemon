defmodule LemonChannels.Adapters.XAPITest.SecretResolverStub do
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def put(name, value) do
    Agent.update(__MODULE__, &Map.put(&1, name, value))
  end

  def resolve(name, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      value -> {:ok, value, :store}
    end
  end
end

defmodule LemonChannels.Adapters.XAPITest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.XAPI
  alias LemonChannels.Adapters.XAPITest.SecretResolverStub

  @x_env_vars [
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_TOKEN_EXPIRES_AT",
    "X_DEFAULT_ACCOUNT_ID",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET"
  ]

  setup do
    previous_config = Application.get_env(:lemon_channels, XAPI)
    previous_use_secrets = Application.get_env(:lemon_channels, :x_api_use_secrets)
    previous_secrets_module = Application.get_env(:lemon_channels, :x_api_secrets_module)
    previous_env = Map.new(@x_env_vars, fn key -> {key, System.get_env(key)} end)

    start_supervised!(SecretResolverStub)

    Application.delete_env(:lemon_channels, XAPI)
    Application.put_env(:lemon_channels, :x_api_use_secrets, false)
    Application.put_env(:lemon_channels, :x_api_secrets_module, SecretResolverStub)
    Enum.each(@x_env_vars, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:lemon_channels, XAPI)
      else
        Application.put_env(:lemon_channels, XAPI, previous_config)
      end

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)

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
    end)

    :ok
  end

  test "configured?/0 reads OAuth2 credentials from secrets store when enabled" do
    Application.put_env(:lemon_channels, :x_api_use_secrets, true)

    SecretResolverStub.put("X_API_CLIENT_ID", "secret-client-id")
    SecretResolverStub.put("X_API_CLIENT_SECRET", "secret-client-secret")
    SecretResolverStub.put("X_API_ACCESS_TOKEN", "secret-access-token")
    SecretResolverStub.put("X_API_REFRESH_TOKEN", "secret-refresh-token")

    assert XAPI.configured?()
    assert XAPI.auth_method() == :oauth2

    config = XAPI.config()
    assert config[:client_id] == "secret-client-id"
    assert config[:client_secret] == "secret-client-secret"
    assert config[:access_token] == "secret-access-token"
    assert config[:refresh_token] == "secret-refresh-token"
  end

  test "configured?/0 reads OAuth2 credentials from environment variables" do
    System.put_env("X_API_CLIENT_ID", "env-client-id")
    System.put_env("X_API_CLIENT_SECRET", "env-client-secret")
    System.put_env("X_API_ACCESS_TOKEN", "env-access-token")
    System.put_env("X_API_REFRESH_TOKEN", "env-refresh-token")

    assert XAPI.configured?()
    assert XAPI.auth_method() == :oauth2

    config = XAPI.config()
    assert config[:client_id] == "env-client-id"
    assert config[:client_secret] == "env-client-secret"
    assert config[:access_token] == "env-access-token"
    assert config[:refresh_token] == "env-refresh-token"
  end

  test "environment fallback still works when app config has nil runtime values" do
    Application.put_env(:lemon_channels, XAPI,
      client_id: nil,
      client_secret: nil,
      access_token: nil
    )

    System.put_env("X_API_CLIENT_ID", "env-client-id")
    System.put_env("X_API_CLIENT_SECRET", "env-client-secret")
    System.put_env("X_API_ACCESS_TOKEN", "env-access-token")

    assert XAPI.configured?()

    config = XAPI.config()
    assert config[:client_id] == "env-client-id"
    assert config[:client_secret] == "env-client-secret"
    assert config[:access_token] == "env-access-token"
  end

  test "present app config values override environment fallback" do
    System.put_env("X_API_CLIENT_ID", "env-client-id")
    System.put_env("X_API_CLIENT_SECRET", "env-client-secret")
    System.put_env("X_API_ACCESS_TOKEN", "env-access-token")

    Application.put_env(:lemon_channels, XAPI,
      client_id: "app-client-id",
      client_secret: "app-client-secret",
      access_token: "app-access-token"
    )

    config = XAPI.config()

    assert config[:client_id] == "app-client-id"
    assert config[:client_secret] == "app-client-secret"
    assert config[:access_token] == "app-access-token"
    assert XAPI.configured?()
  end
end

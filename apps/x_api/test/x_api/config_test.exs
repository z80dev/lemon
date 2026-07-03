defmodule XApiTest.SecretResolverStub do
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

  def fetch_value(name, opts \\ []) do
    case resolve(name, opts) do
      {:ok, value, _source} -> value
      {:error, _reason} -> nil
    end
  end
end

defmodule XApiTest do
  use ExUnit.Case, async: false

  alias XApi
  alias XApiTest.SecretResolverStub

  @legacy_x_api_module :"Elixir.LemonChannels.Adapters.XAPI"

  @x_env_vars [
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_TOKEN_EXPIRES_AT",
    "X_DEFAULT_ACCOUNT_ID",
    "X_DEFAULT_ACCOUNT_USERNAME",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET"
  ]

  setup do
    previous_config = Application.get_env(:x_api, XApi)
    previous_legacy_config = Application.get_env(:lemon_channels, @legacy_x_api_module)
    previous_use_secrets = Application.get_env(:x_api, :use_secrets)
    previous_secrets_module = Application.get_env(:x_api, :secrets_module)
    previous_env = Map.new(@x_env_vars, fn key -> {key, System.get_env(key)} end)

    start_supervised!(SecretResolverStub)

    Application.delete_env(:x_api, XApi)
    Application.delete_env(:lemon_channels, @legacy_x_api_module)
    Application.put_env(:x_api, :use_secrets, false)
    Application.put_env(:x_api, :secrets_module, SecretResolverStub)
    Enum.each(@x_env_vars, &System.delete_env/1)

    on_exit(fn ->
      if is_nil(previous_config) do
        Application.delete_env(:x_api, XApi)
      else
        Application.put_env(:x_api, XApi, previous_config)
      end

      if is_nil(previous_legacy_config) do
        Application.delete_env(:lemon_channels, @legacy_x_api_module)
      else
        Application.put_env(:lemon_channels, @legacy_x_api_module, previous_legacy_config)
      end

      Enum.each(previous_env, fn {key, value} ->
        if is_nil(value) do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)

      if is_nil(previous_use_secrets) do
        Application.delete_env(:x_api, :use_secrets)
      else
        Application.put_env(:x_api, :use_secrets, previous_use_secrets)
      end

      if is_nil(previous_secrets_module) do
        Application.delete_env(:x_api, :secrets_module)
      else
        Application.put_env(:x_api, :secrets_module, previous_secrets_module)
      end
    end)

    :ok
  end

  test "configured?/0 reads OAuth2 credentials from secrets store when enabled" do
    Application.put_env(:x_api, :use_secrets, true)

    SecretResolverStub.put("X_API_CLIENT_ID", "secret-client-id")
    SecretResolverStub.put("X_API_CLIENT_SECRET", "secret-client-secret")
    SecretResolverStub.put("X_API_ACCESS_TOKEN", "secret-access-token")
    SecretResolverStub.put("X_API_REFRESH_TOKEN", "secret-refresh-token")

    assert XApi.configured?()
    assert XApi.auth_method() == :oauth2

    config = XApi.config()
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

    assert XApi.configured?()
    assert XApi.auth_method() == :oauth2

    config = XApi.config()
    assert config[:client_id] == "env-client-id"
    assert config[:client_secret] == "env-client-secret"
    assert config[:access_token] == "env-access-token"
    assert config[:refresh_token] == "env-refresh-token"
  end

  test "search_configured?/0 accepts bearer-token-only search credentials" do
    System.put_env("X_API_BEARER_TOKEN", "env-bearer-token")

    assert XApi.search_configured?()
    refute XApi.configured?()

    config = XApi.config()
    assert config[:bearer_token] == "env-bearer-token"
  end

  test "environment fallback still works when app config has nil runtime values" do
    Application.put_env(:x_api, XApi,
      client_id: nil,
      client_secret: nil,
      access_token: nil
    )

    System.put_env("X_API_CLIENT_ID", "env-client-id")
    System.put_env("X_API_CLIENT_SECRET", "env-client-secret")
    System.put_env("X_API_ACCESS_TOKEN", "env-access-token")

    assert XApi.configured?()

    config = XApi.config()
    assert config[:client_id] == "env-client-id"
    assert config[:client_secret] == "env-client-secret"
    assert config[:access_token] == "env-access-token"
  end

  test "present app config values override environment fallback for static fields" do
    System.put_env("X_API_CLIENT_ID", "env-client-id")
    System.put_env("X_API_CLIENT_SECRET", "env-client-secret")
    System.put_env("X_API_ACCESS_TOKEN", "env-access-token")

    Application.put_env(:x_api, XApi,
      client_id: "app-client-id",
      client_secret: "app-client-secret",
      access_token: "app-access-token"
    )

    config = XApi.config()

    assert config[:client_id] == "app-client-id"
    assert config[:client_secret] == "app-client-secret"
    # Token fields prefer runtime values (secrets/env) to preserve live refresh state.
    assert config[:access_token] == "env-access-token"
    assert XApi.configured?()
  end

  test "legacy lemon_channels app config remains supported" do
    Application.put_env(:lemon_channels, @legacy_x_api_module,
      client_id: "legacy-client-id",
      client_secret: "legacy-client-secret",
      access_token: "legacy-access-token"
    )

    assert XApi.configured?()

    config = XApi.config()
    assert config[:client_id] == "legacy-client-id"
    assert config[:client_secret] == "legacy-client-secret"
    assert config[:access_token] == "legacy-access-token"
  end
end

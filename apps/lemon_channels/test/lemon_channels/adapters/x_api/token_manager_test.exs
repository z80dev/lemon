defmodule LemonChannels.Adapters.XAPI.TokenManager.NonBlockingRefreshTest.SecretSink do
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

defmodule LemonChannels.Adapters.XAPI.TokenManager.NonBlockingRefreshTest do
  @moduledoc """
  Tests for non-blocking token refresh behaviour in TokenManager.

  Verifies:
  - No network I/O happens directly in handle_call
  - At most one refresh runs concurrently (coalescing)
  - All waiters get replies when refresh completes
  - All waiters get error replies on refresh failure
  - Telemetry events are emitted
  """

  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.XAPI
  alias LemonChannels.Adapters.XAPI.TokenManager
  alias LemonChannels.Adapters.XAPI.TokenManager.NonBlockingRefreshTest.SecretSink

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

  describe "non-blocking refresh" do
    test "returns valid token immediately without network call" do
      # Configure a token that is still valid (expires 1 hour from now)
      configure_oauth2_tokens(
        access_token: "valid-token",
        refresh_token: "some-refresh",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      )

      test_pid = self()

      # Stub that tracks whether any HTTP request is made
      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :http_request_made)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{}))
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:ok, "valid-token"} = TokenManager.get_access_token(name)

      # No HTTP request should have been made
      refute_receive :http_request_made, 100
    end

    test "handle_call does not block on network I/O during refresh" do
      # Token is expired, so refresh will be needed
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      test_pid = self()

      # Stub that takes some time (simulates network I/O)
      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:refresh_started, System.monotonic_time(:millisecond)})
        Process.sleep(200)
        send(test_pid, {:refresh_completed, System.monotonic_time(:millisecond)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "new-token",
            "refresh_token" => "new-refresh",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      # Call get_access_token -- it should return after the async refresh completes
      # but the GenServer itself should not be blocked during the refresh.
      # We verify this by making a get_state call while refresh is in flight.

      # Start the token request in a separate process
      caller = Task.async(fn -> TokenManager.get_access_token(name) end)

      # Wait for the refresh to start
      assert_receive {:refresh_started, _}, 1000

      # While refresh is in flight, the GenServer should still respond to other calls
      assert {:ok, _state} = TokenManager.get_state(name)

      # Wait for the refresh to complete and get the result
      assert {:ok, "new-token"} = Task.await(caller, 5000)
    end

    test "coalesces concurrent requests: at most one refresh for many callers" do
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      test_pid = self()
      refresh_count = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(refresh_count, 1, 1)
        send(test_pid, :refresh_started)
        # Slow refresh to allow many callers to pile up
        Process.sleep(300)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "coalesced-token",
            "refresh_token" => "coalesced-refresh",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      # Fire 10 concurrent requests
      tasks =
        for _ <- 1..10 do
          Task.async(fn -> TokenManager.get_access_token(name) end)
        end

      # All should succeed
      results = Enum.map(tasks, &Task.await(&1, 5000))
      assert Enum.all?(results, &match?({:ok, "coalesced-token"}, &1))

      # Only 1 refresh should have been made
      assert :counters.get(refresh_count, 1) == 1
    end

    test "all waiters receive the refreshed token on success" do
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(100)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "shared-new-token",
            "refresh_token" => "shared-new-refresh",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> TokenManager.get_access_token(name) end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5000))

      # All 5 callers should get the same token
      for result <- results do
        assert {:ok, "shared-new-token"} = result
      end
    end

    test "all waiters receive error on refresh failure" do
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(100)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          401,
          Jason.encode!(%{
            "error" => "invalid_grant",
            "error_description" => "Token was invalid"
          })
        )
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> TokenManager.get_access_token(name) end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5000))

      # All 5 callers should get an error
      for result <- results do
        assert {:error, {:refresh_failed, 401, _body}} = result
      end
    end

    test "returns :no_token error when no tokens are available" do
      configure_oauth2_tokens(
        access_token: nil,
        refresh_token: nil,
        token_expires_at: nil
      )

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:error, :no_token} = TokenManager.get_access_token(name)
    end

    test "returns :no_refresh_token when access token expired and no refresh token" do
      configure_oauth2_tokens(
        access_token: "expired",
        refresh_token: nil,
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:error, :no_refresh_token} = TokenManager.get_access_token(name)
    end
  end

  describe "telemetry events" do
    test "emits start and stop events on successful refresh" do
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "telemetry-token",
            "refresh_token" => "telemetry-refresh",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end)

      test_pid = self()

      :telemetry.attach(
        "test-refresh-start",
        [:lemon_channels, :x_api, :token_refresh, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-refresh-stop",
        [:lemon_channels, :x_api, :token_refresh, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-refresh-start")
        :telemetry.detach("test-refresh-stop")
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:ok, "telemetry-token"} = TokenManager.get_access_token(name)

      assert_receive {:telemetry, [:lemon_channels, :x_api, :token_refresh, :start],
                       %{system_time: _}, %{}},
                     1000

      assert_receive {:telemetry, [:lemon_channels, :x_api, :token_refresh, :stop],
                       %{duration: duration}, %{status: :ok}},
                     1000

      assert is_integer(duration)
    end

    test "emits start and stop events with error status on refresh failure" do
      configure_oauth2_tokens(
        access_token: "expired-token",
        refresh_token: "refresh-token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
      )

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{"error" => "server_error"})
        )
      end)

      test_pid = self()

      :telemetry.attach(
        "test-refresh-fail-start",
        [:lemon_channels, :x_api, :token_refresh, :start],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "test-refresh-fail-stop",
        [:lemon_channels, :x_api, :token_refresh, :stop],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("test-refresh-fail-start")
        :telemetry.detach("test-refresh-fail-stop")
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:error, _reason} = TokenManager.get_access_token(name)

      assert_receive {:telemetry, [:lemon_channels, :x_api, :token_refresh, :start],
                       %{system_time: _}, %{}},
                     1000

      assert_receive {:telemetry, [:lemon_channels, :x_api, :token_refresh, :stop],
                       %{duration: _}, %{status: :error, reason: _}},
                     1000
    end
  end

  describe "backward compatibility" do
    test "refresh persists rotated tokens to app config and secrets backend" do
      configure_oauth2_tokens(
        access_token: "old-access",
        refresh_token: "old-refresh",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.to_iso8601()
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

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:ok, "new-access"} = TokenManager.get_access_token(name)

      persisted = SecretSink.values()
      assert persisted["X_API_ACCESS_TOKEN"] == "new-access"
      assert persisted["X_API_REFRESH_TOKEN"] == "new-refresh"
      assert is_binary(persisted["X_API_TOKEN_EXPIRES_AT"])

      app_config = Application.get_env(:lemon_channels, XAPI, [])
      assert app_config[:access_token] == "new-access"
      assert app_config[:refresh_token] == "new-refresh"
      assert is_binary(app_config[:token_expires_at])
    end

    test "update_tokens still works synchronously" do
      configure_oauth2_tokens(
        access_token: "initial-access",
        refresh_token: "initial-refresh",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      )

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:ok, _state} =
               TokenManager.update_tokens(name, %{
                 access_token: "updated-token",
                 refresh_token: "updated-refresh",
                 expires_at: DateTime.utc_now() |> DateTime.add(7200, :second)
               })

      assert {:ok, "updated-token"} = TokenManager.get_access_token(name)
    end

    test "get_state returns current state" do
      configure_oauth2_tokens(
        access_token: "state-token",
        refresh_token: "state-refresh",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      )

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      assert {:ok, %TokenManager{access_token: "state-token"}} = TokenManager.get_state(name)
    end
  end

  describe "timer-based background refresh" do
    test "background refresh does not block the GenServer" do
      # Token expires in 1 second with 300s buffer, so it's already "needs refresh"
      # but the access_token exists so init will schedule_refresh
      configure_oauth2_tokens(
        access_token: "bg-token",
        refresh_token: "bg-refresh",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      )

      Req.Test.stub(__MODULE__, fn conn ->
        Process.sleep(200)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "access_token" => "bg-new-token",
            "refresh_token" => "bg-new-refresh",
            "expires_in" => 7200,
            "token_type" => "Bearer"
          })
        )
      end)

      name = unique_name()
      start_supervised!({TokenManager, [name: name, secrets_module: SecretSink]})

      # Manually trigger the timer-based refresh
      send(GenServer.whereis(name), :refresh_token)

      # GenServer should still be responsive during background refresh
      Process.sleep(50)
      assert {:ok, _state} = TokenManager.get_state(name)
    end
  end

  ## Helpers

  defp configure_oauth2_tokens(config) do
    base = [
      client_id: "test-client-id",
      client_secret: "test-client-secret"
    ]

    # Filter out nil values to avoid overriding with nil
    filtered =
      Enum.reject(config, fn {_k, v} -> is_nil(v) end)

    Application.put_env(:lemon_channels, XAPI, Keyword.merge(base, filtered))
  end

  defp unique_name do
    {:global, {:x_api_token_manager_nonblocking_test, self(), System.unique_integer([:positive])}}
  end
end

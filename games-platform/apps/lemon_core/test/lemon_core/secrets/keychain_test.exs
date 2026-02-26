defmodule LemonCore.Secrets.KeychainTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.Keychain

  # Mock command runners for testing

  # Mock runner that simulates successful key retrieval
  defp mock_runner_get_success(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["find-generic-password", "-s", _, "-a", _, "-w"]} ->
        {"my-secret-key-value\n", 0}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates key not found (exit code 44)
  defp mock_runner_not_found(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["find-generic-password", "-s", _, "-a", _, "-w"]} ->
        {"security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n", 44}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates successful add/update
  defp mock_runner_add_success(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["add-generic-password", "-U" | _]} ->
        {"", 0}

      {"security", ["find-generic-password", "-s", "-a", "-w" | _]} ->
        {"stored-secret-value\n", 0}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates successful delete
  defp mock_runner_delete_success(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["delete-generic-password" | _]} ->
        {"", 0}

      {"security", ["find-generic-password", "-s", _, "-a", _, "-w"]} ->
        {"security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n", 44}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates delete when key doesn't exist
  defp mock_runner_delete_not_found(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["delete-generic-password" | _]} ->
        {"security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n", 44}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that captures custom service/account values
  defp mock_runner_custom_service_account(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["find-generic-password", "-s", "CustomService", "-a", "CustomAccount", "-w"]} ->
        {"custom-service-key\n", 0}

      {"security", ["add-generic-password", "-U", "-s", "CustomService", "-a", "CustomAccount" | _]} ->
        {"", 0}

      {"security", ["delete-generic-password", "-s", "CustomService", "-a", "CustomAccount"]} ->
        {"", 0}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates a timeout (never returns)
  defp mock_runner_timeout(_cmd, _args, _opts) do
    # Sleep longer than any reasonable timeout
    Process.sleep(60_000)
    {"", 0}
  end

  # Mock runner that simulates command failure
  defp mock_runner_command_failed(cmd, args, _opts) do
    case {cmd, args} do
      {"security", _} ->
        {"security: error: User interaction is not allowed.\n", 36}

      _ ->
        {"", 1}
    end
  end

  # Mock runner that simulates empty value
  defp mock_runner_empty_value(cmd, args, _opts) do
    case {cmd, args} do
      {"security", ["find-generic-password" | _]} ->
        {"", 0}

      _ ->
        {"", 1}
    end
  end

  describe "available?/0" do
    test "returns boolean based on platform and security executable" do
      result = Keychain.available?()

      # On macOS with security executable, should return true
      # On other platforms, should return false
      assert is_boolean(result)

      expected =
        match?({:unix, :darwin}, :os.type()) and is_binary(System.find_executable("security"))

      assert result == expected
    end
  end

  describe "get_master_key/1" do
    @moduletag :macos_only

    test "returns {:ok, value} when key exists" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_get_success/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:ok, "my-secret-key-value"} = result
    end

    test "returns {:error, :missing} when key does not exist (exit code 44)" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_not_found/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, :missing} = result
    end

    test "returns {:error, :unavailable} when not on macOS" do
      # This test verifies the behavior when available? returns false
      # We simulate this by checking if we're actually on macOS
      unless Keychain.available?() do
        result = Keychain.get_master_key()
        assert {:error, :unavailable} = result
      end
    end

    test "returns {:error, :missing} for empty value" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_empty_value/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, :missing} = result
    end

    test "returns error when command fails with non-44 exit code" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_command_failed/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, {:command_failed, 36, "security: error: User interaction is not allowed."}} = result
    end

    test "returns {:error, :timeout} when command times out" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_timeout/3,
          service: "TestService",
          account: "TestAccount",
          timeout_ms: 50
        )

      assert {:error, :timeout} = result
    end

    test "uses default service and account when not specified" do
      # This verifies the default values are used
      result =
        Keychain.get_master_key(
          runner: fn cmd, args, _opts ->
            assert cmd == "security"
            assert ["find-generic-password", "-s", "Lemon Secrets", "-a", "default", "-w"] = args
            {"default-key\n", 0}
          end
        )

      assert {:ok, "default-key"} = result
    end

    test "uses custom service and account when specified" do
      result =
        Keychain.get_master_key(
          runner: &mock_runner_custom_service_account/3,
          service: "CustomService",
          account: "CustomAccount"
        )

      assert {:ok, "custom-service-key"} = result
    end
  end

  describe "put_master_key/2" do
    @moduletag :macos_only

    test "stores value successfully" do
      # First store the value
      result =
        Keychain.put_master_key("my-secret-value",
          runner: &mock_runner_add_success/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert :ok = result
    end

    test "returns {:error, :invalid_value} for non-binary value" do
      result = Keychain.put_master_key(12345, [])
      assert {:error, :invalid_value} = result

      result = Keychain.put_master_key(nil, [])
      assert {:error, :invalid_value} = result

      result = Keychain.put_master_key(["list"], [])
      assert {:error, :invalid_value} = result
    end

    test "returns {:error, :unavailable} when not on macOS" do
      unless Keychain.available?() do
        result = Keychain.put_master_key("value", [])
        assert {:error, :unavailable} = result
      end
    end

    test "returns error when command fails" do
      result =
        Keychain.put_master_key("my-secret-value",
          runner: &mock_runner_command_failed/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, {:command_failed, 36, "security: error: User interaction is not allowed."}} = result
    end

    test "uses custom service and account when specified" do
      captured =
        Keychain.put_master_key("custom-value",
          runner: fn cmd, args, _opts ->
            # Verify the service and account are correct
            assert cmd == "security"
            assert "CustomService" in args
            assert "CustomAccount" in args
            assert "custom-value" in args
            assert "-U" in args  # Update flag should be present
            {"", 0}
          end,
          service: "CustomService",
          account: "CustomAccount"
        )

      assert :ok = captured
    end

    test "uses -U flag for update-or-create behavior" do
      Keychain.put_master_key("my-value",
        runner: fn _cmd, args, _opts ->
          assert "-U" in args
          {"", 0}
        end
      )
    end
  end

  describe "delete_master_key/1" do
    @moduletag :macos_only

    test "deletes key successfully" do
      result =
        Keychain.delete_master_key(
          runner: &mock_runner_delete_success/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert :ok = result
    end

    test "returns {:error, :missing} when key does not exist" do
      result =
        Keychain.delete_master_key(
          runner: &mock_runner_delete_not_found/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, :missing} = result
    end

    test "returns {:error, :unavailable} when not on macOS" do
      unless Keychain.available?() do
        result = Keychain.delete_master_key([])
        assert {:error, :unavailable} = result
      end
    end

    test "returns error when command fails" do
      result =
        Keychain.delete_master_key(
          runner: &mock_runner_command_failed/3,
          service: "TestService",
          account: "TestAccount"
        )

      assert {:error, {:command_failed, 36, "security: error: User interaction is not allowed."}} = result
    end

    test "uses custom service and account when specified" do
      captured =
        Keychain.delete_master_key(
          runner: fn cmd, args, _opts ->
            assert cmd == "security"
            assert ["delete-generic-password", "-s", "CustomService", "-a", "CustomAccount"] = args
            {"", 0}
          end,
          service: "CustomService",
          account: "CustomAccount"
        )

      assert :ok = captured
    end

    test "uses default service and account when not specified" do
      captured =
        Keychain.delete_master_key(
          runner: fn cmd, args, _opts ->
            assert cmd == "security"
            assert ["delete-generic-password", "-s", "Lemon Secrets", "-a", "default"] = args
            {"", 0}
          end
        )

      assert :ok = captured
    end
  end

  describe "integration behavior" do
    @moduletag :macos_only

    test "full lifecycle: put, get, delete with mock runner" do
      # Use a mock runner that maintains state across calls
      {:ok, agent} = Agent.start_link(fn -> %{stored: nil} end)

      stateful_runner = fn cmd, args, _opts ->
        state = Agent.get(agent, & &1)

        case {cmd, args} do
          {"security", ["add-generic-password", "-U", "-s", _, "-a", _, "-w", value]} ->
            Agent.update(agent, fn _ -> %{stored: value} end)
            {"", 0}

          {"security", ["find-generic-password", "-s", _, "-a", _, "-w"]} ->
            case state.stored do
              nil -> {"security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n", 44}
              value -> {"#{value}\n", 0}
            end

          {"security", ["delete-generic-password" | _]} ->
            Agent.update(agent, fn _ -> %{stored: nil} end)
            {"", 0}

          _ ->
            {"", 1}
        end
      end

      # Put
      assert :ok =
               Keychain.put_master_key("lifecycle-secret",
                 runner: stateful_runner,
                 service: "LifecycleTest",
                 account: "LifecycleAccount"
               )

      # Get
      assert {:ok, "lifecycle-secret"} =
               Keychain.get_master_key(
                 runner: stateful_runner,
                 service: "LifecycleTest",
                 account: "LifecycleAccount"
               )

      # Delete
      assert :ok =
               Keychain.delete_master_key(
                 runner: stateful_runner,
                 service: "LifecycleTest",
                 account: "LifecycleAccount"
               )

      # Verify deleted
      assert {:error, :missing} =
               Keychain.get_master_key(
                 runner: stateful_runner,
                 service: "LifecycleTest",
                 account: "LifecycleAccount"
               )

      Agent.stop(agent)
    end
  end

  describe "timeout behavior" do
    @moduletag :macos_only

    test "respects custom timeout_ms option" do
      # Use a runner that simulates slow response
      slow_runner = fn _cmd, _args, _opts ->
        Process.sleep(200)
        {"slow-result", 0}
      end

      # With short timeout, should timeout
      result =
        Keychain.get_master_key(
          runner: slow_runner,
          timeout_ms: 50,
          service: "TimeoutTest"
        )

      assert {:error, :timeout} = result

      # With longer timeout, should succeed
      result =
        Keychain.get_master_key(
          runner: slow_runner,
          timeout_ms: 500,
          service: "TimeoutTest"
        )

      assert {:ok, "slow-result"} = result
    end

    test "uses default timeout when not specified" do
      # Verify default timeout is used by checking it doesn't timeout immediately
      # The default is 5000ms, so a quick response should work
      quick_runner = fn _cmd, _args, _opts ->
        {"quick-result", 0}
      end

      result =
        Keychain.get_master_key(
          runner: quick_runner,
          service: "DefaultTimeoutTest"
        )

      assert {:ok, "quick-result"} = result
    end
  end

  describe "command runner injection" do
    @moduletag :macos_only

    test "allows custom command runner for testing" do
      # Use an Agent to capture that the runner was called
      {:ok, agent} = Agent.start_link(fn -> nil end)

      test_runner = fn cmd, args, opts ->
        Agent.update(agent, fn _ -> {cmd, args, opts} end)
        {"test-output", 0}
      end

      Keychain.get_master_key(runner: test_runner)

      # Give the async task time to complete
      Process.sleep(50)

      assert Agent.get(agent, fn state -> state end) ==
               {"security", ["find-generic-password", "-s", "Lemon Secrets", "-a", "default", "-w"],
                [stderr_to_stdout: true]}

      Agent.stop(agent)
    end

    test "passes stderr_to_stdout option to runner" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      Keychain.get_master_key(
        runner: fn _cmd, _args, opts ->
          Agent.update(agent, fn _ -> opts end)
          {"", 0}
        end
      )

      # Give the async task time to complete
      Process.sleep(50)

      assert Agent.get(agent, fn state -> state end) == [stderr_to_stdout: true]

      Agent.stop(agent)
    end
  end
end

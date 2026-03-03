defmodule LemonCore.Secrets.SecretServiceTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.SecretService

  # -- Mock runners -------------------------------------------------------

  defp mock_runner_get_success("secret-tool", ["lookup" | _], _opts) do
    {"my-secret-key-value\n", 0}
  end

  defp mock_runner_get_success(_, _, _), do: {"", 1}

  defp mock_runner_not_found("secret-tool", ["lookup" | _], _opts), do: {"", 1}
  defp mock_runner_not_found(_, _, _), do: {"", 1}

  defp mock_runner_add_success("secret-tool", ["store" | _], _opts), do: {"", 0}
  defp mock_runner_add_success(_, _, _), do: {"", 1}

  defp mock_runner_delete_success("secret-tool", ["clear" | _], _opts), do: {"", 0}
  defp mock_runner_delete_success(_, _, _), do: {"", 1}

  defp mock_runner_delete_not_found("secret-tool", ["clear" | _], _opts), do: {"", 1}
  defp mock_runner_delete_not_found(_, _, _), do: {"", 1}

  defp mock_runner_empty_value("secret-tool", ["lookup" | _], _opts), do: {"", 0}
  defp mock_runner_empty_value(_, _, _), do: {"", 1}

  defp mock_runner_command_failed("secret-tool", _, _opts) do
    {"Cannot autolaunch D-Bus without X11\n", 5}
  end

  defp mock_runner_command_failed(_, _, _), do: {"", 1}

  defp mock_runner_timeout(_cmd, _args, _opts) do
    Process.sleep(60_000)
    {"", 0}
  end

  # -- Tests ---------------------------------------------------------------

  describe "available?/0" do
    test "returns boolean" do
      assert is_boolean(SecretService.available?())
    end

    test "returns false on macOS" do
      if match?({:unix, :darwin}, :os.type()) do
        refute SecretService.available?()
      end
    end
  end

  describe "get_master_key/1" do
    test "returns {:ok, value} when key exists" do
      assert {:ok, "my-secret-key-value"} =
               SecretService.get_master_key(runner: &mock_runner_get_success/3)
    end

    test "returns {:error, :missing} when key not found (exit 1, empty output)" do
      assert {:error, :missing} =
               SecretService.get_master_key(runner: &mock_runner_not_found/3)
    end

    test "returns {:error, :missing} for empty value with exit 0" do
      assert {:error, :missing} =
               SecretService.get_master_key(runner: &mock_runner_empty_value/3)
    end

    test "returns error when command fails" do
      assert {:error, {:command_failed, 5, "Cannot autolaunch D-Bus without X11"}} =
               SecretService.get_master_key(runner: &mock_runner_command_failed/3)
    end

    test "returns {:error, :timeout} when command times out" do
      assert {:error, :timeout} =
               SecretService.get_master_key(
                 runner: &mock_runner_timeout/3,
                 timeout_ms: 50
               )
    end

    test "uses default service and account" do
      result =
        SecretService.get_master_key(
          runner: fn "secret-tool", args, _opts ->
            assert ["lookup", "service", "Lemon Secrets", "account", "default"] = args
            {"default-key\n", 0}
          end
        )

      assert {:ok, "default-key"} = result
    end

    test "uses custom service and account" do
      result =
        SecretService.get_master_key(
          runner: fn "secret-tool", args, _opts ->
            assert ["lookup", "service", "Custom", "account", "admin"] = args
            {"custom-key\n", 0}
          end,
          service: "Custom",
          account: "admin"
        )

      assert {:ok, "custom-key"} = result
    end
  end

  describe "put_master_key/2" do
    test "stores value successfully" do
      assert :ok =
               SecretService.put_master_key("my-secret",
                 runner: &mock_runner_add_success/3
               )
    end

    test "passes stdin value to runner" do
      SecretService.put_master_key("the-value",
        runner: fn "secret-tool", _args, opts ->
          assert opts[:stdin] == "the-value"
          {"", 0}
        end
      )
    end

    test "returns {:error, :invalid_value} for non-binary" do
      assert {:error, :invalid_value} = SecretService.put_master_key(123, [])
    end

    test "returns error when command fails" do
      assert {:error, {:command_failed, 5, "Cannot autolaunch D-Bus without X11"}} =
               SecretService.put_master_key("value",
                 runner: &mock_runner_command_failed/3
               )
    end
  end

  describe "delete_master_key/1" do
    test "deletes key successfully" do
      assert :ok = SecretService.delete_master_key(runner: &mock_runner_delete_success/3)
    end

    test "returns {:error, :missing} when key not found" do
      assert {:error, :missing} =
               SecretService.delete_master_key(runner: &mock_runner_delete_not_found/3)
    end

    test "returns error when command fails" do
      assert {:error, {:command_failed, 5, "Cannot autolaunch D-Bus without X11"}} =
               SecretService.delete_master_key(runner: &mock_runner_command_failed/3)
    end
  end

  describe "integration lifecycle" do
    test "put, get, delete with stateful runner" do
      {:ok, agent} = Agent.start_link(fn -> nil end)

      stateful_runner = fn "secret-tool", args, opts ->
        state = Agent.get(agent, & &1)

        case args do
          ["store" | _] ->
            Agent.update(agent, fn _ -> opts[:stdin] end)
            {"", 0}

          ["lookup" | _] ->
            case state do
              nil -> {"", 1}
              value -> {"#{value}\n", 0}
            end

          ["clear" | _] ->
            Agent.update(agent, fn _ -> nil end)
            {"", 0}
        end
      end

      assert :ok =
               SecretService.put_master_key("lifecycle-secret", runner: stateful_runner)

      assert {:ok, "lifecycle-secret"} =
               SecretService.get_master_key(runner: stateful_runner)

      assert :ok = SecretService.delete_master_key(runner: stateful_runner)

      assert {:error, :missing} =
               SecretService.get_master_key(runner: stateful_runner)

      Agent.stop(agent)
    end
  end
end

defmodule LemonCore.ApplicationTest do
  @moduledoc """
  Tests for LemonCore.Application.

  These tests verify that the application starts correctly with all children
  and that the supervision tree has the expected structure.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Store

  setup do
    assert {:ok, _} = Application.ensure_all_started(:lemon_core)
    :ok
  end

  defp wait_for_pid(name, previous_pid, attempts \\ 20)

  defp wait_for_pid(_name, _previous_pid, 0), do: nil

  defp wait_for_pid(name, previous_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        if Process.alive?(pid) do
          pid
        else
          Process.sleep(50)
          wait_for_pid(name, previous_pid, attempts - 1)
        end

      _ ->
        Process.sleep(50)
        wait_for_pid(name, previous_pid, attempts - 1)
    end
  end

  describe "application startup" do
    test "application is started" do
      assert {:ok, _} = Application.ensure_all_started(:lemon_core)

      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :lemon_core end)
    end

    test "supervisor uses one_for_one strategy" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      assert supervisor_pid != nil

      # Get supervisor state - it's a tuple, not a map
      state = :sys.get_state(supervisor_pid)

      # The state is a tuple where the third element is the strategy
      assert elem(state, 2) == :one_for_one
    end
  end

  describe "supervisor children specification" do
    test "supervisor has exactly 12 children" do
      supervisor_pid = Process.whereis(LemonCore.Supervisor)
      children = Supervisor.which_children(supervisor_pid)

      # Includes LemonCore.UsageLedger, which records finished-run usage, and
      # LemonCore.ExecApprovalExpiry, which expires approvals of ended owners.
      assert length(children) == 12
    end
  end

  describe "child restart behavior" do
    test "supervisor restarts crashed Store child" do
      # Get the original Store pid
      original_pid = Process.whereis(LemonCore.Store)
      assert original_pid != nil

      # Kill the Store process
      Process.exit(original_pid, :kill)

      # Verify Store was restarted
      new_pid = wait_for_pid(LemonCore.Store, original_pid)
      assert new_pid != nil
      assert new_pid != original_pid
      assert Process.alive?(new_pid)
    end
  end

  describe "integration" do
    test "all children can communicate via PubSub" do
      # Subscribe to a test topic
      test_topic = "test:application:#{System.unique_integer([:positive])}"
      :ok = Phoenix.PubSub.subscribe(LemonCore.PubSub, test_topic)

      # Broadcast a message
      message = {:test_message, self(), System.unique_integer([:positive])}
      Phoenix.PubSub.broadcast(LemonCore.PubSub, test_topic, message)

      # Verify we receive the message
      assert_receive ^message, 1000
    end

    test "Store can store and retrieve data after application start" do
      test_key = "application_test:#{System.unique_integer([:positive])}"
      test_value = %{data: "test_value", timestamp: System.system_time(:millisecond)}

      # Store data
      :ok = Store.put(:runs, test_key, test_value)

      # Retrieve data
      retrieved = Store.get(:runs, test_key)
      assert retrieved == test_value

      # Clean up
      Store.delete(:runs, test_key)
    end
  end
end

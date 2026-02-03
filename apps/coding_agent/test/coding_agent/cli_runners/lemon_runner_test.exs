defmodule CodingAgent.CliRunners.LemonRunnerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.CliRunners.LemonRunner

  describe "module API" do
    test "engine/0 returns 'lemon'" do
      assert LemonRunner.engine() == "lemon"
    end

    test "supports_steer?/0 returns true" do
      assert LemonRunner.supports_steer?() == true
    end
  end

  describe "start_link/1" do
    test "requires prompt option" do
      # GenServer.start_link runs init/1 in a separate process, so we get an exit
      # rather than a direct exception. Trap exits to test this gracefully.
      Process.flag(:trap_exit, true)
      result = LemonRunner.start_link(cwd: System.tmp_dir!())

      # Should fail to start - the exact error depends on how GenServer handles
      # the KeyError in init/1
      case result do
        {:error, _reason} ->
          # GenServer returned an error tuple
          :ok

        {:ok, pid} ->
          # If it somehow started, it should exit quickly
          assert_receive {:EXIT, ^pid, _reason}, 1000
      end
    end

    # Note: Full integration tests require CodingAgent.Session to be available,
    # which depends on the coding_agent application being started.
    # These tests are in the coding_agent app's test suite.
  end
end

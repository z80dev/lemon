defmodule CodingAgent.Wasm.SidecarSupervisorTest do
  @moduledoc """
  Tests for the SidecarSupervisor module.

  These tests verify that the dynamic supervisor correctly manages
  WASM sidecar processes per session.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Wasm.{SidecarSupervisor, SidecarSession}

  setup do
    # Start the supervisor if not already running
    case SidecarSupervisor.start_link(name: :test_sidecar_sup) do
      {:ok, pid} -> {:ok, sup: pid}
      {:error, {:already_started, pid}} -> {:ok, sup: pid}
    end
  end

  describe "start_link/1" do
    test "starts the dynamic supervisor", %{sup: _sup} do
      # Supervisor is already started in setup
      assert Process.whereis(:test_sidecar_sup) != nil
    end

    test "can start with custom name" do
      name = :"custom_sidecar_sup_#{:erlang.unique_integer([:positive])}"
      assert {:ok, pid} = SidecarSupervisor.start_link(name: name)
      assert Process.whereis(name) == pid
      Process.exit(pid, :normal)
    end
  end

  describe "start_sidecar/1" do
    test "returns error for invalid configuration" do
      # Try to start with non-existent directory
      result =
        SidecarSupervisor.start_sidecar(
          cwd: "/nonexistent/path/that/does/not/exist",
          session_id: "test-#{:erlang.unique_integer([:positive])}"
        )

      # Should fail because lemon.toml doesn't exist
      assert match?({:error, _}, result)
    end
  end

  describe "stop_sidecar/1" do
    test "returns error for non-existent pid" do
      fake_pid = :c.pid(0, 999_999, 0)
      assert {:error, :not_found} = SidecarSupervisor.stop_sidecar(fake_pid)
    end
  end

  describe "supervisor strategy" do
    test "is a dynamic supervisor", %{sup: sup} do
      # Verify it's a running supervisor process
      assert Process.alive?(sup)
      assert Process.whereis(:test_sidecar_sup) == sup
    end
  end
end

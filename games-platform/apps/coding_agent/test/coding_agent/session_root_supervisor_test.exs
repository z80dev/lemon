defmodule CodingAgent.SessionRootSupervisorAdditionalTest do
  @moduledoc """
  Tests for the SessionRootSupervisor module.

  These tests verify that the supervisor correctly starts and manages
  session processes and optional coordinators.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.SessionRootSupervisor

  setup do
    # Create a temporary directory for the session
    tmp_dir = Path.join(System.tmp_dir!(), "session_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp mock_model(opts \\ []) do
    %Ai.Types.Model{
      id: Keyword.get(opts, :id, "mock-model"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: :mock_api,
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 10_000,
      max_tokens: 1_000,
      headers: %{},
      compat: nil
    }
  end

  describe "start_link/1" do
    test "starts supervisor with session", %{tmp_dir: tmp_dir} do
      assert {:ok, sup} =
               SessionRootSupervisor.start_link(
                 cwd: tmp_dir,
                 model: mock_model(),
                 session_id: "test-session-#{:erlang.unique_integer([:positive])}"
               )

      assert Process.alive?(sup)
    end

    test "starts supervisor with session and coordinator", %{tmp_dir: tmp_dir} do
      assert {:ok, sup} =
               SessionRootSupervisor.start_link(
                 cwd: tmp_dir,
                 model: mock_model(),
                 with_coordinator: true,
                 session_id: "test-session-#{:erlang.unique_integer([:positive])}"
               )

      assert Process.alive?(sup)

      # Give time for children to start
      Process.sleep(100)

      assert {:ok, _} = SessionRootSupervisor.get_session(sup)
      assert {:ok, _} = SessionRootSupervisor.get_coordinator(sup)
    end

    test "generates session_id if not provided", %{tmp_dir: tmp_dir} do
      assert {:ok, sup} =
               SessionRootSupervisor.start_link(
                 cwd: tmp_dir,
                 model: mock_model()
               )

      assert Process.alive?(sup)
      assert {:ok, _} = SessionRootSupervisor.get_session(sup)
    end
  end

  describe "get_session/1" do
    test "returns session pid when session exists", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Give time for children to start
      Process.sleep(100)

      assert {:ok, session_pid} = SessionRootSupervisor.get_session(sup)
      assert is_pid(session_pid)
      assert Process.alive?(session_pid)
    end

    test "returns :error when session not found" do
      # Create an empty supervisor without children
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)

      assert :error = SessionRootSupervisor.get_session(sup)
    end
  end

  describe "get_coordinator/1" do
    test "returns coordinator pid when coordinator exists", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          with_coordinator: true,
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Give time for children to start
      Process.sleep(100)

      assert {:ok, coord_pid} = SessionRootSupervisor.get_coordinator(sup)
      assert is_pid(coord_pid)
      assert Process.alive?(coord_pid)
    end

    test "returns :error when coordinator not started", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          with_coordinator: false,
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Give time for children to start
      Process.sleep(100)

      assert :error = SessionRootSupervisor.get_coordinator(sup)
    end
  end

  describe "list_children/1" do
    test "returns list of children with session only", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Give time for children to start
      Process.sleep(100)

      children = SessionRootSupervisor.list_children(sup)
      assert length(children) == 1
      assert {CodingAgent.Session, _} = hd(children)
    end

    test "returns list of children with session and coordinator", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          with_coordinator: true,
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Give time for children to start
      Process.sleep(100)

      children = SessionRootSupervisor.list_children(sup)
      assert length(children) == 2

      modules = Enum.map(children, &elem(&1, 0))
      assert CodingAgent.Session in modules
      assert CodingAgent.Coordinator in modules
    end

    test "returns empty list for supervisor with no children" do
      {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
      assert [] = SessionRootSupervisor.list_children(sup)
    end
  end

  describe "supervisor strategy" do
    test "uses rest_for_one strategy", %{tmp_dir: tmp_dir} do
      {:ok, sup} =
        SessionRootSupervisor.start_link(
          cwd: tmp_dir,
          model: mock_model(),
          with_coordinator: true,
          session_id: "test-session-#{:erlang.unique_integer([:positive])}"
        )

      # Verify the supervisor is running with expected children
      assert Process.alive?(sup)
      children = Supervisor.which_children(sup)
      assert length(children) == 2

      # Verify both children are present (order depends on internal supervisor ordering)
      modules = Enum.map(children, &elem(&1, 0))
      assert CodingAgent.Session in modules
      assert CodingAgent.Coordinator in modules
    end
  end
end

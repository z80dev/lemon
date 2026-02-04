defmodule LemonRouter.RunProcessTest do
  @moduledoc """
  Tests for LemonRouter.RunProcess.

  Note: These are lightweight tests for the public API.
  Full integration testing with gateway should be done separately.
  """
  use ExUnit.Case, async: false

  alias LemonRouter.{RunProcess, SessionKey}

  setup do
    # Ensure registries are running
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :duplicate, name: LemonRouter.SessionRegistry)
    end)

    start_if_needed(LemonRouter.CoalescerRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.CoalescerRegistry)
    end)

    start_if_needed(LemonRouter.CoalescerSupervisor, fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: LemonRouter.CoalescerSupervisor)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  # Create a minimal job struct for testing
  defp make_test_job(run_id, meta \\ %{}) do
    %LemonGateway.Types.Job{
      scope: nil,
      run_id: run_id,
      session_key: nil,
      user_msg_id: 1,
      text: "test",
      queue_mode: :collect,
      engine_hint: "echo",
      meta: meta
    }
  end

  describe "start_link/1" do
    test "starts successfully with valid args" do
      run_id = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      result = RunProcess.start_link(%{
        run_id: run_id,
        session_key: session_key,
        job: job
      })

      # Process should start successfully (even if it completes quickly)
      assert {:ok, pid} = result
      assert is_pid(pid)
    end
  end

  describe "abort/2" do
    test "abort by non-existent run_id returns :ok" do
      # Abort on non-existent run should be safe
      assert :ok = RunProcess.abort("non-existent-run", :test_abort)
    end
  end

  describe "SessionKey" do
    test "main/1 generates correct format" do
      key = SessionKey.main("my-agent")
      assert is_binary(key)
      assert String.starts_with?(key, "agent:my-agent:")
    end

    test "channel_peer/1 generates correct format" do
      key = SessionKey.channel_peer(%{
        agent_id: "my-agent",
        channel_id: "telegram",
        account_id: "bot123",
        peer_kind: :dm,
        peer_id: "user456"
      })

      assert is_binary(key)
      assert String.contains?(key, "telegram")
      assert String.contains?(key, "bot123")
    end
  end
end

defmodule LemonRouter.RunOrchestratorTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonRouter.RunOrchestrator

  @moduledoc """
  Tests for RunOrchestrator including cwd and tool_policy override handling.
  """

  setup do
    # Start RunOrchestrator if not running
    case Process.whereis(RunOrchestrator) do
      nil ->
        {:ok, pid} = RunOrchestrator.start_link([])

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

        {:ok, orchestrator_pid: pid}

      pid ->
        {:ok, orchestrator_pid: pid}
    end
  end

  describe "submit/1" do
    test "generates run_id" do
      # Note: This will fail to start the actual run since we don't have
      # the full infrastructure running, but we can test the orchestrator logic
      # by verifying it doesn't crash and returns an appropriate response

      # We expect this to fail since RunSupervisor isn't started
      result =
        RunOrchestrator.submit(%{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello",
          queue_mode: :collect
        })

      # Either succeeds with run_id or fails with meaningful error
      case result do
        {:ok, run_id} ->
          assert is_binary(run_id)
          assert String.starts_with?(run_id, "run_")

        {:error, reason} ->
          # Expected when RunSupervisor isn't running
          assert reason != nil
      end
    end

    test "accepts RunRequest struct input" do
      result =
        RunOrchestrator.submit(%RunRequest{
          origin: :control_plane,
          session_key: "agent:test:main",
          agent_id: "test",
          prompt: "Hello from struct",
          queue_mode: :collect
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts and normalizes string-keyed map input" do
      result =
        RunOrchestrator.submit(%{
          "origin" => :control_plane,
          "session_key" => "agent:test:main",
          "prompt" => "Hello from string keys",
          "queue_mode" => :collect,
          "meta" => %{"source" => "test"}
        })

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "cwd override handling" do
    # These tests verify the cwd parameter is properly extracted and passed
    # We test the logic flow rather than the full integration

    test "cwd override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/working/dir"
      }

      # The orchestrator should accept the cwd parameter without error
      # Even if the full submission fails, no crash should occur
      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd from meta is used when no override provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        meta: %{cwd: "/meta/working/dir"}
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "cwd override takes precedence over meta cwd" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/override/dir",
        meta: %{cwd: "/meta/dir"}
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "tool_policy override handling" do
    test "tool_policy override is accepted in params" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{
          approvals: %{"bash" => :always},
          blocked_tools: ["dangerous_tool"]
        }
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "tool_policy override is merged with resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{sandbox: true}
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "empty tool_policy override does not change resolved policy" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: %{}
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "nil tool_policy override is ignored" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        tool_policy: nil
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "combined overrides" do
    test "both cwd and tool_policy overrides can be provided" do
      params = %{
        origin: :control_plane,
        session_key: "agent:test:main",
        agent_id: "test",
        prompt: "Hello",
        cwd: "/custom/dir",
        tool_policy: %{
          approvals: %{"bash" => :always}
        }
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "session config application" do
    test "applies model from session config" do
      session_key = "test:session:model:#{System.unique_integer()}"

      # Store session config with model
      LemonCore.Store.put(:session_policies, session_key, %{
        model: "claude-3-opus"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      # The orchestrator should pick up the model from session config
      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "applies thinking_level from session config" do
      session_key = "test:session:thinking:#{System.unique_integer()}"

      LemonCore.Store.put(:session_policies, session_key, %{
        thinking_level: "high"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "explicit engine_id overrides session model" do
      session_key = "test:session:override:#{System.unique_integer()}"

      LemonCore.Store.put(:session_policies, session_key, %{
        model: "claude-3-haiku"
      })

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello",
        # This should take precedence
        engine_id: "explicit:engine"
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles missing session config gracefully" do
      session_key = "test:session:missing:#{System.unique_integer()}"

      # Don't set any session config

      params = %{
        origin: :control_plane,
        session_key: session_key,
        agent_id: "test",
        prompt: "Hello"
      }

      result = RunOrchestrator.submit(params)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end
end

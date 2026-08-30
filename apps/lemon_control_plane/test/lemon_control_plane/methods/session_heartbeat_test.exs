defmodule LemonControlPlane.Methods.SessionHeartbeatTest.Provider do
  @moduledoc false

  def session_heartbeat(session_key, action, params) do
    Agent.get_and_update(__MODULE__, fn state ->
      {state.result, %{state | calls: [{session_key, action, params} | state.calls]}}
    end)
  end
end

defmodule LemonControlPlane.Methods.SessionHeartbeatTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.AgentRuntime
  alias LemonControlPlane.Methods.SessionHeartbeat
  alias LemonControlPlane.Methods.SessionHeartbeatTest.Provider

  @ctx %{auth: %{role: :admin}}

  setup do
    previous = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

    {:ok, provider} =
      Agent.start_link(fn -> %{result: {:ok, status()}, calls: []} end, name: Provider)

    :ok = AgentRuntime.register(Provider)

    on_exit(fn ->
      if Process.alive?(provider), do: Agent.stop(provider)

      if previous do
        Application.put_env(:lemon_control_plane, :agent_runtime_provider, previous)
      else
        Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
      end
    end)

    :ok
  end

  test "status is the default action and returns a bounded operator snapshot" do
    assert {:ok, result} = SessionHeartbeat.handle(%{"sessionKey" => "agent:main"}, @ctx)

    assert result["sessionKey"] == "agent:main"
    assert result["action"] == "status"
    assert result["heartbeat"]["status"] == "active"
    assert result["heartbeat"]["intervalSeconds"] == 300
    assert result["heartbeat"]["prompt"] == "review active work"
    assert result["summary"]["promptReturned"] == true
    assert result["summary"]["cleanup"]["includesProviderResponses"] == false
    assert calls() == [{"agent:main", :status, %{}}]
  end

  test "set validates and forwards the exact durable-session request" do
    params = %{
      "sessionKey" => "agent:main",
      "action" => "set",
      "intervalSeconds" => 900,
      "prompt" => "  check CI and open reviews  "
    }

    assert {:ok, result} = SessionHeartbeat.handle(params, @ctx)
    assert result["action"] == "set"

    assert calls() == [
             {"agent:main", :set, %{interval_seconds: 900, prompt: "check CI and open reviews"}}
           ]
  end

  test "rejects malformed actions before calling the runtime" do
    assert {:error, {:invalid_request, message, nil}} =
             SessionHeartbeat.handle(
               %{"sessionKey" => "agent:main", "action" => "set", "prompt" => "check"},
               @ctx
             )

    assert message =~ "intervalSeconds is required"
    assert calls() == []

    assert {:error, {:invalid_request, action_message, nil}} =
             SessionHeartbeat.handle(
               %{"sessionKey" => "agent:main", "action" => "explode"},
               @ctx
             )

    assert action_message =~ "action must be one of"
  end

  test "maps runtime lifecycle failures to stable JSON-RPC errors" do
    set_result({:error, :session_not_found})

    assert {:error, {:not_found, "Live session not found", nil}} =
             SessionHeartbeat.handle(%{"sessionKey" => "missing"}, @ctx)

    set_result({:error, :interval_too_small})

    assert {:error, {:invalid_request, "intervalSeconds must be at least 60", nil}} =
             SessionHeartbeat.handle(
               %{
                 "sessionKey" => "agent:main",
                 "action" => "set",
                 "prompt" => "check",
                 "intervalSeconds" => 59
               },
               @ctx
             )
  end

  test "rejects malformed provider state without reflecting it onto the wire" do
    set_result({:ok, %{prompt: "provider-private-value"}})

    assert {:error, {:internal_error, "Session heartbeat runtime returned invalid state", nil}} =
             SessionHeartbeat.handle(%{"sessionKey" => "agent:main"}, @ctx)
  end

  test "declares the method as an admin-only live-session mutation" do
    assert SessionHeartbeat.name() == "sessions.heartbeat"
    assert SessionHeartbeat.scopes() == [:admin]
  end

  defp status do
    now = System.system_time(:millisecond)

    %{
      configured: true,
      status: :active,
      prompt: "review active work",
      interval_seconds: 300,
      fire_count: 4,
      created_at_ms: now - 1_000,
      last_fired_at_ms: now - 500,
      next_fire_at_ms: now + 299_500,
      next_in_seconds: 300
    }
  end

  defp calls, do: Agent.get(Provider, &Enum.reverse(&1.calls))
  defp set_result(result), do: Agent.update(Provider, &%{&1 | result: result})
end

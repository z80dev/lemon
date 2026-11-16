defmodule LemonControlPlane.Methods.SessionsSteerIntegrationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager}
  alias LemonControlPlane.Methods.{SessionsSteerPending, SessionsSteerWithdraw}
  alias LemonCore.AgentRuntime

  @tag :tmp_dir
  test "the public withdrawal RPC removes only the exact native queued steer", %{tmp_dir: cwd} do
    previous = AgentRuntime.provider()
    :ok = AgentRuntime.register(ControlPlaneProvider)
    key = "agent:steer-rpc-#{System.unique_integer([:positive])}:main"

    on_exit(fn ->
      if previous,
        do: AgentRuntime.register(previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)

      File.rm_rf!(SessionManager.get_session_dir(cwd))
    end)

    model = %LemonAi.Types.Model{
      id: "steering-test",
      name: "Steering Test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

    session =
      start_supervised!(
        {Session,
         [
           cwd: cwd,
           session_key: key,
           register: true,
           model: model,
           tools: [],
           stream_fn: fn _, _, _ -> flunk("queued withdrawal must not invoke a model") end
         ]}
      )

    # Idle queueing makes the unbound boundary deterministic: no timer, sleep,
    # provider network call or racing model completion participates in this proof.
    assert :ok = Session.steer(session, "withdraw this correction", id: "withdraw-me")
    assert :ok = Session.steer(session, "keep this correction", id: "keep-me")
    assert {:ok, pending} = SessionsSteerPending.handle(%{"sessionKey" => key}, %{})
    assert Enum.sort(Enum.map(pending["items"], & &1["messageId"])) == ["keep-me", "withdraw-me"]

    target = %{"sessionKey" => key, "messageId" => "withdraw-me"}

    assert {:error, {:not_found, _, _}} =
             SessionsSteerWithdraw.handle(Map.put(target, "sessionKey", key <> "-foreign"), %{})

    assert {:ok, %{"withdrawn" => true, "messageId" => "withdraw-me"}} =
             SessionsSteerWithdraw.handle(target, %{})

    assert {:ok, pending} = SessionsSteerPending.handle(%{"sessionKey" => key}, %{})
    assert Enum.map(pending["items"], & &1["messageId"]) == ["keep-me"]
    assert {:error, {:not_found, _, _}} = SessionsSteerWithdraw.handle(target, %{})
    assert {:error, :not_found} = Session.withdraw_steer(session, "withdraw-me")
  end
end

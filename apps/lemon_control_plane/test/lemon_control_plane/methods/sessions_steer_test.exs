defmodule LemonControlPlane.Methods.SessionsSteerTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    Registry,
    SessionsSteer,
    SessionsSteerPending,
    SessionsSteerWithdraw
  }

  alias LemonCore.AgentRuntime

  defmodule Provider do
    @behaviour LemonCore.AgentRuntime.Provider

    @impl true
    def session_steer(key, run_id, text, id) do
      send(self(), {:steer, key, run_id, text, id})
      result(:steer_result, {:ok, %{id: id, accepted_after_turn: 3}})
    end

    @impl true
    def session_withdraw_steer(key, id) do
      send(self(), {:withdraw, key, id})
      result(:withdraw_result, :ok)
    end

    @impl true
    def session_pending_steers(key) do
      send(self(), {:pending, key})
      result(:pending_result, {:ok, []})
    end

    defp result(key, default) do
      case Process.get(key, default) do
        :raise -> raise "private provider failure"
        :exit -> exit(:receipt_lost)
        :throw -> throw(:private_failure)
        result -> result
      end
    end
  end

  setup do
    previous = AgentRuntime.provider()
    :ok = AgentRuntime.register(Provider)

    on_exit(fn ->
      if previous,
        do: AgentRuntime.register(previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    :ok
  end

  test "registered write methods preserve session, run and message identities" do
    assert {:ok, receipt} = Registry.dispatch("sessions.steer", target(), ctx([:write]))
    assert_receive {:steer, "agent:steering:main", "run-live", "correct direction", "steer-1"}

    assert receipt == %{
             "sessionKey" => "agent:steering:main",
             "runId" => "run-live",
             "messageId" => "steer-1",
             "acceptedAfterTurn" => 3
           }

    assert {:ok, %{"withdrawn" => true, "messageId" => "steer-1"}} =
             Registry.dispatch("sessions.steer.withdraw", target(), ctx([:write]))

    assert_receive {:withdraw, "agent:steering:main", "steer-1"}
    assert {:error, _} = Registry.dispatch("sessions.steer", target(), ctx([:read]))
    assert {:error, _} = Registry.dispatch("sessions.steer.withdraw", target(), ctx([:read]))
    refute_receive {:steer, _, _, _, _}
    refute_receive {:withdraw, _, _}
  end

  test "invalid and unbounded inputs never reach the runtime" do
    for field <- ["sessionKey", "runId", "messageId", "prompt"],
        value <- [nil, "", "   ", <<0>>, 123] do
      assert {:error, {:invalid_params, _, _}} =
               SessionsSteer.handle(Map.put(target(), field, value), %{})
    end

    assert {:error, _} =
             SessionsSteer.handle(Map.put(target(), "prompt", String.duplicate("x", 32_769)), %{})

    assert {:error, _} =
             SessionsSteerWithdraw.handle(
               %{"sessionKey" => "key", "messageId" => String.duplicate("x", 257)},
               %{}
             )

    assert {:error, _} = SessionsSteer.handle(nil, %{})
    assert {:error, _} = SessionsSteerWithdraw.handle([], %{})
    refute_receive {:steer, _, _, _, _}
    refute_receive {:withdraw, _, _}
  end

  test "bound, missing and stale input refusals are not successful withdrawals" do
    Process.put(:withdraw_result, {:error, :not_found})
    assert {:error, {:not_found, _, _}} = SessionsSteerWithdraw.handle(target(), %{})
    Process.put(:steer_result, {:error, :stale_run})
    assert {:error, {:conflict, _, _}} = SessionsSteer.handle(target(), %{})
  end

  test "lost and malformed mutation receipts remain unknown, never safe to replay" do
    for result <- [:raise, :exit, :throw, nil, :unexpected] do
      Process.put(:withdraw_result, result)

      assert {:error, {:unavailable, _, %{"retrySafe" => false}}} =
               SessionsSteerWithdraw.handle(target(), %{})
    end

    for result <- [
          nil,
          {:ok, %{id: "wrong", accepted_after_turn: 3}},
          {:ok, %{id: "steer-1", accepted_after_turn: -1}}
        ] do
      Process.put(:steer_result, result)

      assert {:error, {:unavailable, _, %{"retrySafe" => false}}} =
               SessionsSteer.handle(target(), %{})
    end
  end

  test "pending reads project only identities, turn indexes and bounded previews" do
    Process.put(
      :pending_result,
      {:ok,
       [
         %{
           id: "steer-1",
           text: String.duplicate("x", 600),
           accepted_after_turn: 3,
           private: "secret"
         },
         %{id: "steer-2", text: "second", accepted_after_turn: 4}
       ]}
    )

    assert {:ok, result} =
             Registry.dispatch(
               "sessions.steer.pending",
               Map.put(target(), "limit", 1),
               ctx([:read, :content])
             )

    assert result == %{
             "sessionKey" => "agent:steering:main",
             "items" => [
               %{
                 "messageId" => "steer-1",
                 "preview" => String.duplicate("x", 512),
                 "acceptedAfterTurn" => 3
               }
             ],
             "truncated" => true,
             "contentWithheld" => false
           }

    assert {:error, _} = Registry.dispatch("sessions.steer.pending", target(), ctx([:write]))
  end

  test "failed, malformed or missing providers never confirm an empty pending queue" do
    for result <- [{:error, :not_found}, :raise, :exit, {:ok, [%{}]}, nil] do
      Process.put(:pending_result, result)
      assert {:error, {:unavailable, _, _}} = SessionsSteerPending.handle(target(), %{})
    end

    Application.delete_env(:lemon_core, :agent_runtime_provider)
    assert {:error, {:unavailable, _, _}} = SessionsSteerPending.handle(target(), %{})

    assert {:error, {:unavailable, _, %{"reason" => "unavailable"}}} =
             SessionsSteerWithdraw.handle(target(), %{})
  end

  defp target do
    %{
      "sessionKey" => "agent:steering:main",
      "runId" => "run-live",
      "messageId" => "steer-1",
      "prompt" => "correct direction"
    }
  end

  defp ctx(scopes), do: %{auth: %{role: :operator, scopes: scopes}}
end

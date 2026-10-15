defmodule LemonControlPlane.Methods.SessionsReadTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{Registry, SessionDetail, SessionsGet, SessionsHistory}
  alias LemonCore.{RunStore, SessionLifecycle}

  setup do
    key = "agent:lifecycle_read_#{System.unique_integer([:positive])}:main"
    agent = LemonCore.SessionKey.agent_id(key)
    :ok = RunStore.create_session_index(key, agent, :tui)
    on_exit(fn -> SessionLifecycle.delete(key) end)
    %{key: key, agent: agent}
  end

  test "daemon lookup and cold session detail preserve durable naming and pin state", %{key: key} do
    {:ok, _} = Application.ensure_all_started(:lemon_router)

    assert {:ok, _} =
             SessionLifecycle.patch(key, %{
               title: "Native fork source",
               pinned: true,
               archived: false
             })

    assert {:ok, %{"session" => row}} =
             Registry.dispatch("sessions.get", %{"sessionKey" => key}, read_context())

    assert row["sessionKey"] == key
    assert row["title"] == "Native fork source"
    assert row["pinned"]
    assert {:ok, detail} = SessionDetail.handle(%{"sessionKey" => key}, %{})
    assert detail["session"]["title"] == "Native fork source"
    assert detail["session"]["pinned"]
  end

  test "durable history is redacted and distinct from native chat messages", %{
    key: key,
    agent: agent
  } do
    secret = "sk-" <> String.duplicate("a", 48)

    assert :ok =
             RunStore.finalize("read-run-#{key}", %{
               session_key: key,
               agent_id: agent,
               origin: :tui,
               prompt: "api_key=#{secret}",
               completed: %{ok: true, answer: "Validation succeeded"}
             })

    assert {:ok, %{"session" => row, "history" => [run]}} =
             Registry.dispatch(
               "sessions.history",
               %{"sessionKey" => key, "limit" => 1},
               read_context()
             )

    assert row.session_key == key
    assert run.run_id == "read-run-#{key}"
    assert run.answer == "Validation succeeded"
    refute Jason.encode!(run) =~ secret
  end

  test "unknown keys are not fabricated and limits are enforced" do
    for handler <- [SessionsGet, SessionsHistory] do
      assert {:error, {:not_found, _, _}} =
               handler.handle(%{"sessionKey" => "tui-unindexed-session"}, %{})
    end

    assert {:error, {:invalid_params, _, _}} =
             SessionsHistory.handle(%{"sessionKey" => "missing", "limit" => 201}, %{})

    assert {:error, {:invalid_params, _, _}} = SessionsGet.handle(%{"sessionKey" => ""}, %{})
    assert Authorize.required_scopes("sessions.get") == [:read]
    assert Authorize.required_scopes("sessions.history") == [:read]

    assert {:error, _} =
             Registry.dispatch("sessions.get", %{"sessionKey" => "missing"}, %{
               auth: %{role: :node, scopes: [:invoke]}
             })
  end

  test "known zero-run forks have real metadata and an empty run history", %{key: key} do
    assert {:ok, %{"session" => row, "history" => []}} =
             SessionsHistory.handle(%{"sessionKey" => key}, %{})

    assert row.run_count == 0
  end

  defp read_context, do: %{auth: %{role: :operator, scopes: [:read]}}
end

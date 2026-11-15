defmodule LemonAgent.ModelRuntime.SessionPinsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.SessionPins

  setup do
    SessionPins.reset()
    on_exit(fn -> SessionPins.reset() end)
    :ok
  end

  test "short-lived callers do not own pins and an absent owner is not recreated" do
    table = :lemon_agent_session_pins
    owner = Process.whereis(SessionPins)
    assert :ets.info(table, :owner) == owner

    task = Task.async(fn -> SessionPins.pin("caller", "openai", "ref", "model") end)
    monitor = Process.monitor(task.pid)
    assert :ok = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert %{credential_ref: "ref"} = SessionPins.get("caller")
    assert :ets.info(table, :owner) == owner

    :ok = Supervisor.terminate_child(LemonAgent.Supervisor, SessionPins)

    try do
      tasks =
        for _ <- 1..16 do
          Task.async(fn ->
            :ok = SessionPins.pin("absent", "openai", "ref", "model")
            SessionPins.get("absent")
          end)
        end

      assert Enum.map(tasks, &Task.await/1) == List.duplicate(nil, 16)
      assert SessionPins.sweep(0) == 0
      assert :ets.whereis(table) == :undefined
    after
      {:ok, _} = Supervisor.restart_child(LemonAgent.Supervisor, SessionPins)
    end

    assert :ets.info(table, :owner) == Process.whereis(SessionPins)
    assert SessionPins.get("caller") == nil
  end

  test "pins and reads back a candidate per session scope" do
    assert SessionPins.get("session-1") == nil

    :ok = SessionPins.pin("session-1", "zai", "secret:llm_zai_api_key", nil)

    assert SessionPins.get("session-1") == %{
             provider: "zai",
             model_id: nil,
             credential_ref: "secret:llm_zai_api_key"
           }

    assert SessionPins.get("session-2") == nil
  end

  test "re-pinning replaces the existing pin" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a", nil)
    :ok = SessionPins.pin("session-1", "openai", "ref_b", nil)

    assert SessionPins.get("session-1") == %{
             provider: "openai",
             model_id: nil,
             credential_ref: "ref_b"
           }
  end

  test "clear removes the pin" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a", nil)
    :ok = SessionPins.clear("session-1")

    assert SessionPins.get("session-1") == nil
  end

  test "nil and :global scopes are no-ops" do
    assert SessionPins.pin(nil, "zai", "ref_a", nil) == :ok
    assert SessionPins.pin(:global, "zai", "ref_a", nil) == :ok

    assert SessionPins.get(nil) == nil
    assert SessionPins.get(:global) == nil
    assert SessionPins.clear(nil) == :ok
    assert SessionPins.clear(:global) == :ok
  end

  test "model pins match only the committed model, including canonical provider names" do
    :ok = SessionPins.pin("model-pin", "openai_codex", "ref", "gpt-5")
    pin = SessionPins.get("model-pin")
    assert SessionPins.matches?(pin, :openai_codex, "gpt-5")
    refute SessionPins.matches?(pin, :openai_codex, "gpt-4")
    refute SessionPins.matches?(pin, :openai, "gpt-5")
    assert SessionPins.matches?(%{pin | model_id: nil}, :openai_codex, "gpt-4")
  end
end

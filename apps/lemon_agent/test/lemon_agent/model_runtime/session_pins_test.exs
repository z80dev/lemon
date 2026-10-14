defmodule LemonAgent.ModelRuntime.SessionPinsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.SessionPins

  setup do
    SessionPins.reset()
    on_exit(fn -> SessionPins.reset() end)
    :ok
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

    assert SessionPins.get("session-1") == %{provider: "openai", model_id: nil, credential_ref: "ref_b"}
  end

  test "clear removes the pin" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a", nil)
    :ok = SessionPins.clear("session-1")

    assert SessionPins.get("session-1") == nil
  end

  test "sweep deletes pins older than the TTL and keeps fresh ones" do
    :ok = SessionPins.pin("session-old", "zai", "ref_a", nil)

    # Let the wall clock advance past the sweep cutoff. The TTL is wide enough
    # that the fresh pin cannot age out between being written and swept even on
    # a slow, descheduled runner.
    Process.sleep(550)

    :ok = SessionPins.pin("session-fresh", "openai", "ref_b", nil)

    assert SessionPins.sweep(500) == 1
    assert SessionPins.get("session-old") == nil
    assert SessionPins.get("session-fresh") == %{provider: "openai", model_id: nil, credential_ref: "ref_b"}
  end

  test "re-pinning refreshes the TTL timestamp" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a", nil)
    Process.sleep(550)
    :ok = SessionPins.pin("session-1", "zai", "ref_a", nil)

    assert SessionPins.sweep(500) == 0
    assert SessionPins.get("session-1") == %{provider: "zai", model_id: nil, credential_ref: "ref_a"}
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
    assert SessionPins.matches?(pin, :"openai-codex", "gpt-5")
    refute SessionPins.matches?(pin, :"openai-codex", "gpt-4")
    refute SessionPins.matches?(pin, :openai, "gpt-5")
    assert SessionPins.matches?(%{pin | model_id: nil}, :"openai-codex", "gpt-4")
  end
end

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

    :ok = SessionPins.pin("session-1", "zai", "secret:llm_zai_api_key")

    assert SessionPins.get("session-1") == %{
             provider: "zai",
             credential_ref: "secret:llm_zai_api_key"
           }

    assert SessionPins.get("session-2") == nil
  end

  test "re-pinning replaces the existing pin" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a")
    :ok = SessionPins.pin("session-1", "openai", "ref_b")

    assert SessionPins.get("session-1") == %{provider: "openai", credential_ref: "ref_b"}
  end

  test "clear removes the pin" do
    :ok = SessionPins.pin("session-1", "zai", "ref_a")
    :ok = SessionPins.clear("session-1")

    assert SessionPins.get("session-1") == nil
  end

  test "nil and :global scopes are no-ops" do
    assert SessionPins.pin(nil, "zai", "ref_a") == :ok
    assert SessionPins.pin(:global, "zai", "ref_a") == :ok

    assert SessionPins.get(nil) == nil
    assert SessionPins.get(:global) == nil
    assert SessionPins.clear(nil) == :ok
    assert SessionPins.clear(:global) == :ok
  end
end

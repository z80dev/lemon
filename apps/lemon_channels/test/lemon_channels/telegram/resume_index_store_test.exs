defmodule LemonChannels.Telegram.ResumeIndexStoreTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonCore.{ResumeToken, Store}

  @tables [:telegram_msg_resume, :telegram_msg_session]

  setup do
    on_exit(fn ->
      Enum.each(@tables, &clear_table/1)
    end)

    :ok
  end

  test "stores and reads generation-scoped resume and session entries" do
    resume = %ResumeToken{engine: "codex", value: "resume-123"}

    assert :ok = ResumeIndexStore.put_resume("default", 100, 200, 300, resume, generation: 2)

    assert :ok =
             ResumeIndexStore.put_session("default", 100, 200, 300, "session-123", generation: 2)

    assert ResumeIndexStore.get_resume("default", 100, 200, 300, generation: 2) == resume
    assert ResumeIndexStore.get_session("default", 100, 200, 300, generation: 2) == "session-123"
  end

  test "falls back to legacy generationless keys for generation 0 lookups" do
    legacy_resume = %ResumeToken{engine: "claude", value: "legacy"}

    assert :ok =
             Store.put(:telegram_msg_resume, {"default", 42, nil, 7}, legacy_resume)

    assert :ok =
             Store.put(:telegram_msg_session, {"default", 42, nil, 7}, "legacy-session")

    assert ResumeIndexStore.get_resume("default", 42, nil, 7, generation: 0) == legacy_resume
    assert ResumeIndexStore.get_session("default", 42, nil, 7, generation: 0) == "legacy-session"
  end

  test "delete_thread removes both legacy and scoped entries up to the requested generation" do
    assert :ok =
             ResumeIndexStore.put_resume("default", 9, 10, 11, %{engine: "codex", value: "g0"})

    assert :ok = ResumeIndexStore.put_session("default", 9, 10, 11, "session-g0")

    assert :ok =
             ResumeIndexStore.put_resume("default", 9, 10, 12, %{engine: "codex", value: "g1"},
               generation: 1
             )

    assert :ok = ResumeIndexStore.put_session("default", 9, 10, 12, "session-g1", generation: 1)

    assert :ok =
             ResumeIndexStore.put_resume("default", 9, 10, 13, %{engine: "codex", value: "g3"},
               generation: 3
             )

    assert :ok = ResumeIndexStore.put_session("default", 9, 10, 13, "session-g3", generation: 3)

    assert :ok = ResumeIndexStore.delete_thread("default", 9, 10, generation: 1)

    assert ResumeIndexStore.get_resume("default", 9, 10, 11, generation: 0) == nil
    assert ResumeIndexStore.get_session("default", 9, 10, 11, generation: 0) == nil
    assert ResumeIndexStore.get_resume("default", 9, 10, 12, generation: 1) == nil
    assert ResumeIndexStore.get_session("default", 9, 10, 12, generation: 1) == nil

    assert ResumeIndexStore.get_resume("default", 9, 10, 13, generation: 3) == %ResumeToken{
             engine: "codex",
             value: "g3"
           }

    assert ResumeIndexStore.get_session("default", 9, 10, 13, generation: 3) == "session-g3"
  end

  defp clear_table(table) do
    Enum.each(Store.list(table), fn {key, _value} ->
      Store.delete(table, key)
    end)
  end
end

defmodule LemonChannels.Telegram.StateStoreTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.StateStore
  alias LemonCore.Store

  @tables [
    :telegram_session_model,
    :telegram_default_model,
    :telegram_default_thinking,
    :telegram_selected_resume,
    :telegram_thread_generation
  ]

  setup do
    on_exit(fn ->
      Enum.each(@tables, &clear_table/1)
    end)

    :ok
  end

  test "persists and deletes session and default preferences" do
    session_key = "telegram:session:model"
    scope_key = {"default", 123, 456}

    assert :ok = StateStore.put_session_model(session_key, "gpt-5")
    assert StateStore.get_session_model(session_key) == "gpt-5"
    assert :ok = StateStore.delete_session_model(session_key)
    assert StateStore.get_session_model(session_key) == nil

    default_model = %{provider: "openai", model: "gpt-5"}
    thinking = %{thinking_level: "high"}

    assert :ok = StateStore.put_default_model(scope_key, default_model)
    assert StateStore.get_default_model(scope_key) == default_model

    assert :ok = StateStore.put_default_thinking(scope_key, thinking)
    assert StateStore.get_default_thinking(scope_key) == thinking

    assert :ok = StateStore.delete_default_model(scope_key)
    assert :ok = StateStore.delete_default_thinking(scope_key)
    assert StateStore.get_default_model(scope_key) == nil
    assert StateStore.get_default_thinking(scope_key) == nil
  end

  test "persists selected resume and thread generation state" do
    key = {"default", 321, nil}
    resume = %{engine: "codex", value: "resume-1"}

    assert :ok = StateStore.put_selected_resume(key, resume)
    assert StateStore.get_selected_resume(key) == resume

    assert :ok = StateStore.put_thread_generation(key, 4)
    assert StateStore.get_thread_generation(key) == 4

    assert :ok = StateStore.delete_selected_resume(key)
    assert :ok = StateStore.delete_thread_generation(key)
    assert StateStore.get_selected_resume(key) == nil
    assert StateStore.get_thread_generation(key) == nil
  end

  defp clear_table(table) do
    Enum.each(Store.list(table), fn {key, _value} ->
      Store.delete(table, key)
    end)
  end
end

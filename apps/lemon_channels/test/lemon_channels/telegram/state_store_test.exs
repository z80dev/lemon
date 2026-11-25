defmodule LemonChannels.Telegram.StateStoreTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.StateStore
  alias LemonCore.Store

  @tables [
    :telegram_selected_resume,
    :telegram_thread_generation
  ]

  setup do
    on_exit(fn ->
      Enum.each(@tables, &clear_table/1)
    end)

    :ok
  end

  test "model and thinking preferences are not stored here" do
    Code.ensure_loaded!(StateStore)

    for fun <- ~w(get_session_model put_session_model delete_session_model get_default_model
                  put_default_model delete_default_model get_default_thinking
                  put_default_thinking delete_default_thinking)a do
      refute Enum.any?(0..2, &function_exported?(StateStore, fun, &1)),
             "StateStore.#{fun} is a second model policy plane"
    end
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

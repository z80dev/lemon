defmodule LemonCore.RunStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunStore

  test "appends, fetches, finalizes, and lists run history through the typed wrapper" do
    session_key = "agent:test:main:#{System.unique_integer([:positive])}"
    run_id = "run_#{System.unique_integer([:positive])}"

    assert :ok = RunStore.append_event(run_id, %{type: :prompt, text: "hello", session_key: session_key})
    assert is_map(RunStore.get(run_id))
    assert :ok =
             RunStore.finalize(run_id, %{
               completed: %{ok: true, answer: "world"},
               prompt: "hello",
               session_key: session_key
             })

    assert eventually(fn ->
             Enum.any?(RunStore.history(session_key, limit: 10), fn {stored_run_id, _} ->
               stored_run_id == run_id
             end)
           end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end

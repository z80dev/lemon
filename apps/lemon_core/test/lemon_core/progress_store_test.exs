defmodule LemonCore.ProgressStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProgressStore

  test "stores and deletes progress mappings through the typed wrapper" do
    scope = "agent:test:main:#{System.unique_integer([:positive])}"
    progress_msg_id = System.unique_integer([:positive])
    run_id = "run_#{System.unique_integer([:positive])}"

    assert :ok = ProgressStore.put(scope, progress_msg_id, run_id)
    assert ProgressStore.get_run(scope, progress_msg_id) == run_id
    assert :ok = ProgressStore.delete(scope, progress_msg_id)
    assert ProgressStore.get_run(scope, progress_msg_id) == nil
  end
end

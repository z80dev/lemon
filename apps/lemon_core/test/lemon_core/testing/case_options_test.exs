defmodule LemonCore.Testing.CaseOptionsTest do
  # `with_store: true` passed to `use` must start the Store (#713).
  use LemonCore.Testing.Case, async: false, with_store: true

  test "use option with_store: true starts LemonCore.Store", %{harness: harness} do
    assert is_pid(Process.whereis(LemonCore.Store))
    assert harness.store == LemonCore.Store
  end
end

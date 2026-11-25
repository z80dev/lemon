defmodule LemonPlatformTest.Testing.CaseDefaultOptionsTest do
  use LemonPlatformTest.Testing.Case, async: true

  test "without with_store the harness does not claim a store", %{harness: harness} do
    assert harness.store == nil
  end

  @tag with_store: true
  test "a with_store tag still starts the store", %{harness: harness} do
    assert harness.store == LemonCore.Store
    assert is_pid(Process.whereis(LemonCore.Store))
  end
end

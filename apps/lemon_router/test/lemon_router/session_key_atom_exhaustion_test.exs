defmodule LemonRouter.SessionKeyAtomExhaustionTest do
  # This test measures global atom table growth and is sensitive to concurrent
  # test activity. Keep it synchronous to avoid flakiness.
  use ExUnit.Case, async: false

  alias LemonRouter.SessionKey

  test "does not create new atoms for invalid peer_kind values" do
    initial_count = :erlang.system_info(:atom_count)

    for i <- 1..100 do
      SessionKey.parse("agent:a:tg:bot:malicious_kind_#{i}:123")
    end

    final_count = :erlang.system_info(:atom_count)

    assert final_count - initial_count < 10,
           "Atom count increased by #{final_count - initial_count}, possible atom leak"
  end
end


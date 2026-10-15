defmodule LemonRouter.SessionKeyAtomExhaustionTest do
  use ExUnit.Case, async: true

  alias LemonCore.SessionKey

  test "does not create new atoms for invalid peer_kind values" do
    suffix = System.unique_integer([:positive])

    for i <- 1..100 do
      peer_kind = "malicious_kind_#{suffix}_#{i}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(peer_kind) end

      assert {:error, :invalid_peer_kind} =
               SessionKey.parse("agent:a:tg:bot:#{peer_kind}:123")

      # Check the attacker-controlled atom itself, not VM-wide growth from
      # unrelated module loading or background processes.
      assert_raise ArgumentError, fn -> String.to_existing_atom(peer_kind) end
    end
  end
end

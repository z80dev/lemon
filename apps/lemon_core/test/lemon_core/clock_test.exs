defmodule LemonCore.ClockTest do
  @moduledoc """
  Tests for the Clock module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Clock

  doctest LemonCore.Clock

  describe "now_ms/0" do
    test "returns current time in milliseconds" do
      before = System.system_time(:millisecond)
      now = Clock.now_ms()
      after_time = System.system_time(:millisecond)

      assert is_integer(now)
      assert now >= before
      assert now <= after_time
    end
  end
end

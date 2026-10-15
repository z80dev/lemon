defmodule CodingAgent.ApplicationTest do
  use ExUnit.Case, async: false

  describe "SessionSupervisor functionality" do
    test "can look up non-existent session" do
      result = CodingAgent.SessionSupervisor.lookup("non-existent-session-id")
      assert result == :error
    end
  end
end

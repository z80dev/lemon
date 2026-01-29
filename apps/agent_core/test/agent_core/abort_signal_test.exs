defmodule AgentCore.AbortSignalTest do
  use ExUnit.Case, async: true

  alias AgentCore.AbortSignal

  describe "abort signal lifecycle" do
    test "aborted?/1 toggles with abort and clear" do
      ref = AbortSignal.new()

      assert AbortSignal.aborted?(ref) == false

      assert :ok = AbortSignal.abort(ref)
      assert AbortSignal.aborted?(ref) == true

      assert :ok = AbortSignal.clear(ref)
      assert AbortSignal.aborted?(ref) == false
    end

    test "aborted?/1 returns false for nil" do
      assert AbortSignal.aborted?(nil) == false
    end
  end
end

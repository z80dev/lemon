defmodule LemonGateway.Sms.ToolDeadlineTest do
  use ExUnit.Case, async: true

  test "SMS waits retain caller-selected deadlines while inbox reads inherit the default" do
    assert LemonGateway.Tools.SmsWaitForCode.tool("/tmp", []).timeout_ms == :infinity
    assert LemonGateway.Tools.SmsListMessages.tool("/tmp", []).timeout_ms == nil
  end
end

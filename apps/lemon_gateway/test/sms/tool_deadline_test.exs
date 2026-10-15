defmodule LemonGateway.Sms.ToolDeadlineTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Tools.{SmsListMessages, SmsWaitForCode}

  test "SMS waits retain caller-selected deadlines while inbox reads inherit the default" do
    assert SmsWaitForCode.tool("/tmp", []).timeout_ms == :infinity
    assert SmsListMessages.tool("/tmp", []).timeout_ms == nil
  end
end

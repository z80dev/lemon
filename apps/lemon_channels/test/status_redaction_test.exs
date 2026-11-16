defmodule LemonChannels.StatusRedactionTest do
  use ExUnit.Case, async: true

  test "registry redacts adapter credentials, health messages and crash diagnostics" do
    secret = "private-channel-message-credential-token"

    status = %{
      state: %{plugins: %{secret => secret}, health: %{secret => %{message: secret}}},
      message: {:adapter_status, secret, %{reason: secret}},
      reason: {:error, secret},
      log: [{:in, secret}]
    }

    assert LemonChannels.Registry.format_status(status) == %{
             state: :redacted,
             message: :redacted,
             reason: :redacted,
             log: []
           }

    refute inspect(LemonChannels.Registry.format_status(status)) =~ secret
    assert LemonChannels.Registry.format_status(%{state: secret}) == %{state: :redacted}
  end
end

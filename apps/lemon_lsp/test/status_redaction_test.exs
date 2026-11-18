defmodule LemonLsp.StatusRedactionTest do
  use ExUnit.Case, async: true

  test "server manager redacts protocol content, launch settings and crash diagnostics" do
    secret = "private-lsp-document-path-env-token"

    status = %{
      state: %{sessions: %{secret => %{buffer: secret, env: secret}}, recent_sessions: [secret]},
      message: {:request, secret},
      reason: {:error, secret},
      log: [{:out, secret}]
    }

    assert LemonLsp.ServerManager.format_status(status) == %{
             state: :redacted,
             message: :redacted,
             reason: :redacted,
             log: []
           }

    refute inspect(LemonLsp.ServerManager.format_status(status)) =~ secret
    assert LemonLsp.ServerManager.format_status(%{state: secret}) == %{state: :redacted}
  end

  test "session process redacts document state, launch settings and crash diagnostics" do
    secret = "private-lsp-session-env-token"

    status = %{
      state: %{sessions: %{secret => %{initialization_options: %{"token" => secret}}}},
      message: {:forward, {:request, secret}, self()},
      reason: {:error, secret},
      log: [{:in, secret}]
    }

    redacted = LemonLsp.Session.format_status(status)

    assert redacted == %{state: :redacted, message: :redacted, reason: :redacted, log: []}
    refute inspect(redacted) =~ secret
  end
end

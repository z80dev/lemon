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
end

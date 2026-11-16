defmodule CodingAgent.StatusRedactionTest do
  use ExUnit.Case, async: true

  for module <- [
        CodingAgent.ProcessStoreServer,
        CodingAgent.TaskStoreServer,
        CodingAgent.ParentQuestionStoreServer
      ] do
    @server module

    test "#{module} inherits durable owner status redaction" do
      secret = "private-command-path-prompt-token"

      status = %{
        state: %{dets_path: secret, pending: %{secret => %{command: secret, env: secret}}},
        message: {:transaction, secret},
        reason: {:storage_error, secret},
        log: [{:in, secret}]
      }

      assert @server.format_status(status) == %{
               state: :redacted,
               message: :redacted,
               reason: :redacted,
               log: []
             }

      refute inspect(@server.format_status(status)) =~ secret
      assert @server.format_status(%{state: secret}) == %{state: :redacted}
    end
  end
end

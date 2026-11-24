defmodule LemonAi.StatusRedactionTest do
  use ExUnit.Case, async: true

  for module <- [LemonAi.CircuitBreaker, LemonAi.EventStream] do
    @server module

    test "#{module} redacts state, current message, crash reason and debug log" do
      secret = "private-provider-prompt-token"

      status = %{
        state: %{events: [secret], last_failure_reason: secret, last_errors: %{secret => secret}},
        message: {:request, secret},
        reason: {:error, secret},
        log: [{:in, secret}],
        unrelated: :retained
      }

      assert @server.format_status(status) == %{
               state: :redacted,
               message: :redacted,
               reason: :redacted,
               log: [],
               unrelated: :retained
             }

      refute inspect(@server.format_status(status)) =~ secret
      assert @server.format_status(%{state: secret}) == %{state: :redacted}
    end
  end

  test "live stream status does not expose queued content" do
    stream = start_supervised!({LemonAi.EventStream, owner: self()})
    secret = "private-stream-content-token"

    assert :ok = LemonAi.EventStream.push(stream, {:text_delta, secret})
    refute inspect(:sys.get_status(stream)) =~ secret
  end
end

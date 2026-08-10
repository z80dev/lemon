defmodule LemonPlatformTest.EmailPluginComplianceTest do
  @moduledoc """
  The kit's `PluginCase` run against the email adapter.

  Email is inbound-only for now, which makes it the cheapest adapter to validate
  end to end: `deliver/1` answers `{:error, :not_implemented}` for every payload
  and `start_link/0` returns `:ignore`, so both the deliver probe and
  `register_and_start_adapter/2` are free of side effects.

  The fixtures are provider webhook bodies rather than synthetic maps, so the
  suite checks the RFC 2822 threading path produces a routable message.
  """

  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: LemonChannels.Adapters.Email,
    start_adapter: true,
    deliver_probe: {__MODULE__, :text_payload},
    inbound_fixtures: {__MODULE__, :webhook_bodies}

  alias LemonChannels.OutboundPayload

  def text_payload(_context) do
    OutboundPayload.new(
      channel_id: "email",
      account_id: "compliance",
      peer: %{kind: :dm, id: "someone@example.com", thread_id: nil},
      kind: :text,
      content: "never sent — outbound is not implemented"
    )
  end

  def webhook_bodies(_context) do
    [
      %{
        "from" => "sender@example.com",
        "to" => "agent@example.com",
        "subject" => "a question",
        "text" => "what is the status?",
        "message_id" => "<abc@example.com>"
      },
      %{
        "from" => "sender@example.com",
        "to" => "agent@example.com",
        "subject" => "Re: a question",
        "text" => "following up",
        "message_id" => "<def@example.com>",
        "in_reply_to" => "<abc@example.com>",
        "references" => "<abc@example.com>"
      }
    ]
  end
end

defmodule LemonPlatformTest.EmailPluginComplianceTest do
  @moduledoc """
  The kit's `PluginCase` run against the email adapter.

  `deliver/1` sends real mail now, so the probe has to be a payload that cannot
  reach anyone. `:reaction` is that payload: email has no such concept, the
  adapter's `meta/0` says so, and it is refused before any configuration is
  read — which keeps the probe side-effect-free no matter what relay the host
  running the suite happens to have configured.

  `start_link/0` still returns `:ignore` (the adapter registers an HTTP route
  and owns no process), so `register_and_start_adapter/2` is free of side
  effects too.

  The fixtures are provider webhook bodies rather than synthetic maps, so the
  suite checks the RFC 2822 threading path produces a routable message.
  """

  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: LemonChannels.Adapters.Email,
    start_adapter: true,
    deliver_probe: {__MODULE__, :unsendable_payload},
    inbound_fixtures: {__MODULE__, :webhook_bodies}

  alias LemonChannels.OutboundPayload

  def unsendable_payload(_context) do
    OutboundPayload.new(
      channel_id: "email",
      account_id: "compliance",
      peer: %{kind: :dm, id: "someone@example.com", thread_id: nil},
      kind: :reaction,
      content: "👍"
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

defmodule LemonChannels.Adapters.Email do
  @moduledoc """
  Email channel adapter (Phase 2.4/B3).

  Email is the one gateway ingress surface that is genuinely message-shaped, so
  it is the one ported to `LemonChannels.Plugin`; the "Transports" section of
  `apps/lemon_gateway/README.md` explains why webhook, SMS and voice stay in
  `lemon_gateway` (decision D2 in `docs/platform-split.md`).

  Both halves are here: inbound parses a provider webhook payload into a
  `LemonCore.InboundMessage`, and `deliver/1` sends the reply over SMTP through
  `LemonChannels.Adapters.Email.Outbound`.

  ## Threading

  Email's `References` header is a *list* of ancestors, while
  `LemonCore.InboundMessage`'s `reply_to_id` is a single optional id. The
  adapter therefore owns its own thread resolution: `thread_id/1` computes a
  stable id from the message alone, and
  `LemonChannels.Adapters.Email.ThreadStore` remembers which thread each message
  id belongs to — so a chain met out of order still converges, and so the reply
  has a subject and a reference chain to send, neither of which the outbound
  payload carries. This is channel-owned state, the same way Telegram owns its
  message-id tables, not a gap in the `Plugin` contract.

  ## Configuring

      config :lemon_channels, LemonChannels.Adapters.Email,
        webhook_token: "…",
        from: "agent@example.com",
        smtp_relay: "mail.example.com",
        smtp_username: "…",
        smtp_password: "…"

  The canonical TOML `[gateway]` config's `email` block is read as well, so a
  deployment configured while email lived in the gateway keeps working. See
  `LemonChannels.Adapters.Email.Config`.

  ## Receiving — off until you turn it on

  The adapter is registered by default, but **inbound mail is not**. Outbound
  works as soon as a relay is configured; receiving takes three more deliberate
  steps, because an inbound mail endpoint is a public door into an agent and
  nobody should open one by upgrading:

      config :lemon_channels, LemonChannels.InboundHttp,
        enabled: true,
        port: 4090,
        ip: {127, 0, 0, 1}

      config :lemon_channels, LemonChannels.Adapters.Email,
        webhook_token: "a long random string",
        inbound: %{
          allowed_senders: ["you@example.com"],
          authserv_id: "mx.your-provider.example"
        }

  With the listener on, the adapter registers
  `LemonChannels.Adapters.Email.Webhook` at `POST /email`, and your provider
  should send there with the token in an `x-webhook-token` header. Without the
  token every request is refused with a 401 — an open endpoint would be a spam
  relay into someone's agent — and without the listener nothing binds a port at
  all. This is the same posture the gateway transport it replaced had: dead
  until explicitly enabled.

  The token only proves the request came from your provider; anyone can mail
  the provider address with any `From`. Senders are therefore authorized
  separately by `LemonChannels.Adapters.Email.SenderAuth`: the `From` address
  must be in `gateway.email.inbound.allowed_senders`, and your provider's
  `Authentication-Results` verdict stamped with
  `gateway.email.inbound.authserv_id` must authenticate the `From` domain
  (DMARC pass, or DKIM pass signed by that domain). Missing either setting
  refuses every message with a 403. Only for a provider that supplies no verdict
  at all, `sender_auth: "from_only_unsafe"` admits allowlisted addresses on the
  `From` header alone — which anyone can forge — and is logged as a warning at
  startup. Thread state is kept per inbox and sender (see
  `LemonChannels.Adapters.Email.ThreadStore`). Accepted mail reaches the agent
  fenced as untrusted email content (`LemonAgent.Security.ExternalContent`),
  never as instructions.

  Point the listener at loopback and put a reverse proxy in front of it unless
  you have a reason not to.
  """

  @behaviour LemonChannels.Plugin

  require Logger

  alias LemonAgent.Security.ExternalContent
  alias LemonChannels.Adapters.Email.{Address, Attachments, MessageId, Outbound, ThreadStore}
  alias LemonCore.InboundMessage

  @channel_id "email"

  @impl true
  def id, do: @channel_id

  @impl true
  def meta do
    %{
      label: "Email",
      capabilities: %{
        edit_support: false,
        delete_support: false,
        thread_support: true,
        reaction_support: false,
        voice_support: false,
        image_support: true,
        file_support: true,
        # No hard ceiling in the protocol; providers differ. Left unset rather
        # than inventing a number the platform would then treat as truth.
        chunk_limit: nil
      },
      docs: nil
    }
  end

  @impl true
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker, restart: :temporary}
  end

  @doc """
  Registers the webhook handler. Returns `:ignore` so the adapter occupies no
  process — all it needs is a route.

  When the route is registered, the inbound sender policy is checked and every
  `LemonChannels.Adapters.Email.SenderAuth.config_warnings/1` entry is logged:
  an endpoint that refuses everything, or one running the unsafe
  `from_only_unsafe` opt-out, should never be silent.
  """
  @spec start_link() :: :ignore
  def start_link do
    case LemonChannels.InboundHttp.register(@channel_id, __MODULE__.Webhook) do
      :ok ->
        __MODULE__.Config.get()
        |> __MODULE__.SenderAuth.config_warnings()
        |> Enum.each(fn warning -> Logger.warning(warning) end)

        :ignore

      {:error, :not_running} ->
        Logger.debug("email adapter: inbound http listener not running; no route registered")
        :ignore
    end
  end

  @impl true
  def normalize_inbound(raw) when is_map(raw) do
    parsed = parse(raw)

    case parsed.from do
      nil ->
        {:error, :missing_from}

      from ->
        account_id = primary_recipient(parsed.to)
        # Thread state is owned by this inbox and this sender: another sender
        # naming one of these message ids never reaches it. See ThreadStore.
        scope = ThreadStore.scope(account_id, from)
        thread = ThreadStore.resolve(parsed, thread_id(parsed), scope)
        {attachments, writes} = Attachments.prepare(parsed.attachments)

        _ = ThreadStore.record_inbound(parsed, thread, scope)
        _ = Attachments.schedule(writes)

        {:ok,
         InboundMessage.new(
           channel_id: @channel_id,
           account_id: account_id,
           peer: %{kind: :dm, id: from, thread_id: thread},
           sender: %{id: from, username: from, display_name: parsed.from_name},
           message: %{
             id: parsed.message_id,
             text: fenced_text(parsed, attachments),
             timestamp: System.system_time(:millisecond),
             reply_to_id: parsed.in_reply_to
           },
           raw: raw,
           meta: %{
             subject: parsed.subject,
             to: parsed.to,
             references: parsed.references,
             attachments: attachments
           }
         )}
    end
  end

  def normalize_inbound(_raw), do: {:error, :invalid_payload}

  @impl true
  def deliver(payload), do: Outbound.deliver(payload)

  @impl true
  def gateway_methods, do: []

  @doc """
  Resolves a stable thread id from a message alone.

  Prefers the oldest ancestor the message names so every message in a chain
  lands on the same id regardless of which one arrives first: the first entry of
  `References`, else `In-Reply-To`, else the message's own id. Falls back to the
  subject with any reply/forward prefixes stripped, so a client that drops
  threading headers still groups sensibly.

  Pure, and the seed rather than the last word: `normalize_inbound/1` asks
  `LemonChannels.Adapters.Email.ThreadStore` first, which knows the threads of
  messages this adapter has already seen and can therefore join a chain whose
  members name different ancestors.
  """
  @spec thread_id(map()) :: binary()
  def thread_id(parsed) do
    cond do
      is_list(parsed.references) and parsed.references != [] -> List.first(parsed.references)
      is_binary(parsed.in_reply_to) -> parsed.in_reply_to
      is_binary(parsed.message_id) -> parsed.message_id
      true -> "subject:" <> normalized_subject(parsed.subject)
    end
  end

  @doc false
  @spec parse(map()) :: map()
  def parse(raw) do
    %{
      from: raw |> fetch(["from", "sender"]) |> address(),
      from_name: raw |> fetch(["from_name", "fromName"]) |> blank_to_nil(),
      to: raw |> fetch(["to", "recipient"]) |> address_list(),
      subject: raw |> fetch(["subject"]) |> blank_to_nil(),
      text: raw |> fetch(["text", "body-plain", "plain"]) |> blank_to_nil(),
      html: raw |> fetch(["html", "body-html"]) |> blank_to_nil(),
      message_id:
        raw |> fetch(["message_id", "messageId", "Message-Id"]) |> MessageId.normalize(),
      in_reply_to:
        raw |> fetch(["in_reply_to", "inReplyTo", "In-Reply-To"]) |> MessageId.normalize(),
      references: raw |> fetch(["references", "References"]) |> MessageId.list(),
      attachments: raw |> fetch(["attachments", "files", "attachment"]) |> attachment_list()
    }
  end

  defp fetch(raw, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(raw, key) do
        {:ok, value} -> value
        :error -> Map.get(raw, String.to_atom(key))
      end
    end)
  rescue
    # String.to_atom on an unknown key is fine; guard against exotic key types.
    ArgumentError -> nil
  end

  # The prompt an engine sees is `message.text` and nothing else, so an
  # attachment the agent cannot see the path of may as well not have arrived.
  # Everything in it was written by whoever sent the mail, so subject, body and
  # attachment lines are fenced as untrusted email content; the fence also
  # neutralizes any marker the sender embedded to close it early.
  defp fenced_text(parsed, attachments) do
    parsed
    |> message_text(attachments)
    |> ExternalContent.wrap_external_content(
      source: :email,
      sender: parsed.from,
      subject: parsed.subject
    )
  end

  defp message_text(parsed, attachments) do
    case Attachments.describe(attachments) do
      [] -> body_text(parsed)
      lines -> Enum.join([body_text(parsed), "", "Attachments:" | lines], "\n")
    end
  end

  defp body_text(parsed) do
    parsed.text || strip_html(parsed.html) || ""
  end

  defp strip_html(html) when is_binary(html),
    do: html |> String.replace(~r/<[^>]*>/, " ") |> squeeze()

  defp strip_html(_html), do: nil

  defp squeeze(text) when is_binary(text),
    do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp primary_recipient([first | _]), do: first
  defp primary_recipient(_), do: @channel_id

  # The whole-mailbox parser shared with outbound delivery: the address that is
  # authorized here is exactly the one replies are sent to. See `Address`.
  defp address(value), do: Address.parse(value)

  defp address_list(nil), do: []

  defp address_list(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)
  end

  defp address_list(values) when is_list(values) do
    values |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)
  end

  defp address_list(_), do: []

  defp attachment_list(values) when is_list(values), do: values
  defp attachment_list(values) when is_map(values), do: Map.values(values)
  defp attachment_list(_), do: []

  defp normalized_subject(subject) when is_binary(subject) do
    subject
    |> String.replace(~r/^\s*((re|fwd|fw)\s*:\s*)+/i, "")
    |> squeeze()
    |> String.downcase()
  end

  defp normalized_subject(_subject), do: ""

  # Anything that is not a binary is treated as absent rather than passed on.
  # A urlencoded body can put a list in any field (`subject[]=a&subject[]=b`)
  # and JSON can put an object there, so every text field arrives untyped. The
  # alternative — picking an element, or stringifying — invents a message the
  # sender did not send; `normalize_inbound/1` would rather see the field as
  # missing. Without this, string functions downstream raise, and
  # `c:LemonChannels.Plugin.normalize_inbound/1` must not raise.
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end

defmodule LemonChannels.Adapters.Email do
  @moduledoc """
  Email channel adapter — **inbound half only** (Phase 2.4/B3).

  Email is the one gateway ingress surface that is genuinely message-shaped, so
  it is the one being ported to `LemonChannels.Plugin`; see
  `docs/platform/transport-unification.md` for why webhook, SMS and voice are
  staying in `lemon_gateway`.

  ## Scope, and what is deliberately missing

  This lands the inbound path: parsing a provider webhook payload into a
  `LemonCore.InboundMessage`, including RFC 2822 thread resolution. **Outbound
  delivery is not implemented** — `deliver/1` returns
  `{:error, :not_implemented}`, and `LemonGateway.Transports.Email` remains
  registered and untouched, so nothing has cut over and no behaviour has
  changed for anyone. Outbound and the cutover are a separate piece of work,
  with `LemonGateway.Transports.Email.Outbound`'s characterization tests
  (`apps/lemon_gateway/test/transports/email/outbound_test.exs`) as the contract
  to port against.

  Returning an explicit error rather than a stub `{:ok, ref}` is deliberate: a
  silent success would let a caller believe mail was sent.

  ## Threading

  Email's `References` header is a *list* of ancestors, while
  `LemonCore.InboundMessage`'s `reply_to_id` is a single optional id. The
  adapter therefore owns its own thread resolution — `thread_id/1` folds
  `In-Reply-To` and `References` into one stable id — and passes the immediate
  parent as `reply_to_id`. This is channel-owned state, the same way Telegram
  owns its message-id tables, not a gap in the `Plugin` contract.

  ## Receiving

  The adapter registers `LemonChannels.Adapters.Email.Webhook` on
  `LemonChannels.InboundHttp` at boot, so inbound mail arrives at
  `POST /email`. That listener is disabled unless configured, so this adapter is
  inert in a default runtime.
  """

  @behaviour LemonChannels.Plugin

  require Logger

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
  """
  @spec start_link() :: :ignore
  def start_link do
    case LemonChannels.InboundHttp.register(@channel_id, __MODULE__.Webhook) do
      :ok ->
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
        thread = thread_id(parsed)

        {:ok,
         InboundMessage.new(
           channel_id: @channel_id,
           account_id: primary_recipient(parsed.to),
           peer: %{kind: :dm, id: from, thread_id: thread},
           sender: %{id: from, username: from, display_name: parsed.from_name},
           message: %{
             id: parsed.message_id,
             text: body_text(parsed),
             timestamp: System.system_time(:millisecond),
             reply_to_id: parsed.in_reply_to
           },
           raw: raw,
           meta: %{
             subject: parsed.subject,
             to: parsed.to,
             references: parsed.references,
             attachments: parsed.attachments
           }
         )}
    end
  end

  def normalize_inbound(_raw), do: {:error, :invalid_payload}

  @impl true
  def deliver(_payload), do: {:error, :not_implemented}

  @impl true
  def gateway_methods, do: []

  @doc """
  Resolves a stable thread id for an email.

  Prefers the oldest known ancestor so every message in a chain lands on the
  same id regardless of which one arrives first: the first entry of
  `References`, else `In-Reply-To`, else the message's own id. Falls back to the
  subject with any reply/forward prefixes stripped, so a client that drops
  threading headers still groups sensibly.
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
      message_id: raw |> fetch(["message_id", "messageId", "Message-Id"]) |> message_id(),
      in_reply_to: raw |> fetch(["in_reply_to", "inReplyTo", "In-Reply-To"]) |> message_id(),
      references: raw |> fetch(["references", "References"]) |> reference_list(),
      attachments: raw |> fetch(["attachments"]) |> attachment_list()
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

  defp body_text(parsed) do
    parsed.text || strip_html(parsed.html) || ""
  end

  defp strip_html(nil), do: nil
  defp strip_html(html), do: html |> String.replace(~r/<[^>]*>/, " ") |> squeeze()

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp primary_recipient([first | _]), do: first
  defp primary_recipient(_), do: @channel_id

  defp address(nil), do: nil

  defp address(value) when is_binary(value) do
    # "Display Name <a@b.c>" -> "a@b.c"
    case Regex.run(~r/<([^>]+)>/, value) do
      [_, addr] -> String.downcase(String.trim(addr))
      _ -> value |> String.trim() |> String.downcase() |> blank_to_nil()
    end
  end

  defp address(_), do: nil

  defp address_list(nil), do: []

  defp address_list(value) when is_binary(value) do
    value |> String.split(",") |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)
  end

  defp address_list(values) when is_list(values) do
    values |> Enum.map(&address/1) |> Enum.reject(&is_nil/1)
  end

  defp address_list(_), do: []

  defp message_id(nil), do: nil

  defp message_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> blank_to_nil()
  end

  defp message_id(_), do: nil

  defp reference_list(nil), do: []

  defp reference_list(value) when is_binary(value) do
    value
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&message_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp reference_list(values) when is_list(values) do
    values |> Enum.map(&message_id/1) |> Enum.reject(&is_nil/1)
  end

  defp reference_list(_), do: []

  defp attachment_list(values) when is_list(values), do: values
  defp attachment_list(_), do: []

  defp normalized_subject(nil), do: ""

  defp normalized_subject(subject) do
    subject
    |> String.replace(~r/^\s*((re|fwd|fw)\s*:\s*)+/i, "")
    |> squeeze()
    |> String.downcase()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end

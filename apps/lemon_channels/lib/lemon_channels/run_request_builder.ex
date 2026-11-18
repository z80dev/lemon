defmodule LemonChannels.RunRequestBuilder do
  @moduledoc false

  alias LemonCore.{InboundMessage, ResumeToken, RunRequest, SessionKey}

  @spec from_inbound(InboundMessage.t()) :: RunRequest.t()
  def from_inbound(%InboundMessage{} = msg) do
    meta = normalize_meta(msg.meta)
    session_key = resolve_session_key(msg, meta)
    agent_id = meta_value(meta, :agent_id) || SessionKey.agent_id(session_key) || "default"

    RunRequest.new(%{
      origin: :channel,
      session_key: session_key,
      agent_id: agent_id,
      prompt: message_text(msg),
      images: Map.get(msg.message, :images, []),
      queue_mode: meta_value(meta, :queue_mode),
      model: meta_value(meta, :model),
      resume: normalize_resume_token(meta_value(meta, :resume)),
      cwd: meta_value(meta, :cwd),
      meta: put_transport_meta(meta, msg)
    })
  end

  # Channels whose sender address is asserted by the payload rather than
  # authenticated by the transport. Their identities are never verified, so
  # they cannot claim owner status or select an existing memory peer.
  @unverified_sender_channels ~w(email)

  @doc """
  Overlay the transport-derived routing fields on `meta`.

  `channel_context` (read by the router policy for per-channel restrictions and
  the group approval floor) and `channel_identity` (read by memory and approval
  code) are always derived from the transport-normalized message; caller meta
  cannot supply either. Every channel-origin `RunRequest` must carry them, so
  any channel-side request built outside `from_inbound/1` uses this function.
  """
  @spec put_transport_meta(map(), InboundMessage.t() | map()) :: map()
  def put_transport_meta(meta, %{channel_id: _, peer: peer} = msg) when is_map(meta) do
    meta
    |> Map.drop([:channel_context, "channel_context", :channel_identity, "channel_identity"])
    |> Map.merge(%{
      channel_id: msg.channel_id,
      account_id: Map.get(msg, :account_id),
      peer: peer,
      sender: Map.get(msg, :sender),
      raw: Map.get(msg, :raw),
      channel_context: channel_context(msg),
      channel_identity: channel_identity(msg)
    })
  end

  defp channel_context(msg) do
    %{
      channel_id: msg.channel_id,
      account_id: Map.get(msg, :account_id),
      peer_kind: Map.get(msg.peer, :kind),
      peer_id: Map.get(msg.peer, :id),
      thread_id: Map.get(msg.peer, :thread_id)
    }
  end

  defp channel_identity(%{channel_id: channel, sender: %{id: sender} = identity})
       when is_binary(channel) and is_binary(sender) and sender != "" do
    verified? = channel not in @unverified_sender_channels

    %{
      channel_id: channel,
      sender_id: sender,
      is_bot: Map.get(identity, :bot, false) == true,
      owner?: verified? and Map.get(identity, :owner?, false) == true,
      verified?: verified?
    }
  end

  # A message without a transport sender id (e.g. a Telegram channel post)
  # must never fall back to the configured owner's memory identity: it gets an
  # unverified identity scoped to its peer.
  defp channel_identity(%{channel_id: channel, peer: peer}) do
    %{
      channel_id: channel,
      sender_id: "unidentified:#{Map.get(peer, :kind)}:#{Map.get(peer, :id)}",
      is_bot: false,
      owner?: false,
      verified?: false
    }
  end

  @spec resolve_session_key(InboundMessage.t(), map()) :: binary()
  def resolve_session_key(%InboundMessage{} = msg, meta \\ nil) do
    meta = normalize_meta(meta || msg.meta)

    candidate =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" -> meta[:session_key]
        is_binary(meta["session_key"]) and meta["session_key"] != "" -> meta["session_key"]
        true -> nil
      end

    if is_binary(candidate) and SessionKey.valid?(candidate) do
      candidate
    else
      SessionKey.channel_peer(%{
        agent_id: meta_value(meta, :agent_id) || "default",
        channel_id: msg.channel_id,
        account_id: msg.account_id,
        peer_kind: msg.peer.kind,
        peer_id: msg.peer.id,
        thread_id: msg.peer.thread_id
      })
    end
  end

  defp message_text(%InboundMessage{message: %{text: text}}) when is_binary(text), do: text
  defp message_text(_), do: ""

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp meta_value(meta, key) when is_atom(key),
    do: Map.get(meta, key) || Map.get(meta, Atom.to_string(key))

  defp normalize_resume_token(%ResumeToken{engine: "lemon"} = resume), do: resume

  defp normalize_resume_token(%{engine: "lemon", value: value}) when is_binary(value) do
    %ResumeToken{engine: "lemon", value: value}
  end

  defp normalize_resume_token(%{"engine" => "lemon", "value" => value}) when is_binary(value) do
    %ResumeToken{engine: "lemon", value: value}
  end

  defp normalize_resume_token(_), do: nil
end

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
      queue_mode: meta_value(meta, :queue_mode),
      engine_id: meta_value(meta, :engine_id),
      model: meta_value(meta, :model),
      resume: normalize_resume_token(meta_value(meta, :resume)),
      cwd: meta_value(meta, :cwd),
      meta:
        Map.merge(meta, %{
          channel_id: msg.channel_id,
          account_id: msg.account_id,
          peer: msg.peer,
          sender: msg.sender,
          raw: msg.raw
        })
    })
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

  defp normalize_resume_token(%ResumeToken{} = resume), do: resume

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil
end

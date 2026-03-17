defmodule LemonChannels.Adapters.WhatsApp.Bridge do
  @moduledoc false
  alias LemonChannels.Adapters.WhatsApp.PortServer

  def connect(port_server, cfg) do
    payload = %{
      "op" => "connect",
      "credentials_path" => cfg_value(cfg, :credentials_path),
      "session_name" => cfg_value(cfg, :session_name),
      "pairing_phone" => cfg_value(cfg, :pairing_phone)
    } |> drop_nil_values()
    PortServer.command(port_server, payload)
  end

  def send_text(port_server, params) do
    # params has: id, jid, text, reply_to
    payload = %{
      "op" => "send_text",
      "id" => params.id,
      "jid" => params.jid,
      "text" => params.text,
      "reply_to" => params[:reply_to]
    } |> drop_nil_values()
    PortServer.command(port_server, payload)
  end

  def send_media(port_server, params) do
    # params has: id, jid, file_path, media_type, caption, ptt
    payload = %{
      "op" => "send_media",
      "id" => params.id,
      "jid" => params.jid,
      "file_path" => params.file_path,
      "media_type" => params.media_type,
      "caption" => params[:caption],
      "ptt" => params[:ptt] || false
    } |> drop_nil_values()
    PortServer.command(port_server, payload)
  end

  def send_reaction(port_server, params) do
    payload = %{
      "op" => "send_reaction",
      "id" => params.id,
      "jid" => params.jid,
      "message_id" => params.message_id,
      "emoji" => params.emoji,
      "from_me" => params[:from_me] || false
    } |> drop_nil_values()
    PortServer.command(port_server, payload)
  end

  def typing(port_server, jid, composing \\ true) do
    PortServer.command(port_server, %{"op" => "typing", "jid" => jid, "composing" => composing})
  end

  def read(port_server, keys) when is_list(keys) do
    PortServer.command(port_server, %{"op" => "read", "keys" => keys})
  end

  def group_metadata(port_server, params) do
    payload = %{"op" => "group_metadata", "id" => params.id, "jid" => params.jid}
    PortServer.command(port_server, payload)
  end

  def disconnect(port_server) do
    PortServer.command(port_server, %{"op" => "disconnect"})
  end

  # private helpers (same as XMTP)
  defp cfg_value(cfg, key) when is_map(cfg), do: Map.get(cfg, key) || Map.get(cfg, to_string(key))
  defp cfg_value(_, _), do: nil
  defp drop_nil_values(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end

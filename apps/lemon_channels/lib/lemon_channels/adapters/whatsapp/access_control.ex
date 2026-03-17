defmodule LemonChannels.Adapters.WhatsApp.AccessControl do
  @moduledoc """
  Pure functions for WhatsApp access control.

  DM modes: :pairing, :allowlist, :open, :disabled
  Group modes: :open, :allowlist, :disabled
  """

  @doc """
  Main entry point. Returns true if the message from jid should be processed.
  event may contain :mentioned_jids for group mention gating.
  """
  def allowed?(config, jid, event) do
    cond do
      self_chat?(config, jid) -> false
      is_group_jid?(jid) -> group_allowed?(config, jid) and not mention_gated?(config, jid, event)
      is_dm_jid?(jid) -> dm_allowed?(config, jid)
      true -> false
    end
  end

  @doc "Returns true if the DM from jid is allowed based on dm_mode config."
  def dm_allowed?(config, jid) do
    mode = config[:dm_mode] || config["dm_mode"] || :open

    case mode do
      :disabled -> false
      :open -> true
      :allowlist -> in_allowlist?(config, jid)
      :pairing -> in_allowlist?(config, jid)
      _ -> false
    end
  end

  @doc "Returns true if the group message from jid is allowed based on group_mode config."
  def group_allowed?(config, jid) do
    mode = config[:group_mode] || config["group_mode"] || :disabled

    case mode do
      :disabled -> false
      :open -> true
      :allowlist -> in_allowlist?(config, jid)
      _ -> false
    end
  end

  @doc """
  Returns true if the bot must be @mentioned but was not.
  For groups with mention_gated: true, the bot JID must appear in mentioned_jids.
  """
  def mention_gated?(config, _jid, event) do
    gated? = config[:mention_gated] || config["mention_gated"] || false

    if gated? do
      own_jid = config[:own_jid] || config["own_jid"]
      mentioned = event[:mentioned_jids] || event["mentioned_jids"] || []

      own_jid == nil or own_jid not in mentioned
    else
      false
    end
  end

  @doc "Returns true if jid ends with @g.us (group JID)."
  def is_group_jid?(jid) when is_binary(jid), do: String.ends_with?(jid, "@g.us")
  def is_group_jid?(_), do: false

  @doc "Returns true if jid ends with @s.whatsapp.net (DM JID)."
  def is_dm_jid?(jid) when is_binary(jid), do: String.ends_with?(jid, "@s.whatsapp.net")
  def is_dm_jid?(_), do: false

  @doc "Extracts the phone number (or group id) from a JID by taking everything before @."
  def phone_from_jid(jid) when is_binary(jid) do
    jid |> String.split("@") |> List.first()
  end

  def phone_from_jid(_), do: nil

  @doc "Returns true if the phone number from jid is in the config allowlist."
  def in_allowlist?(config, jid) do
    allowlist = config[:allowlist] || config["allowlist"] || []
    phone = phone_from_jid(jid)

    if is_binary(phone) do
      normalized = String.trim_leading(phone, "+")

      Enum.any?(allowlist, fn entry ->
        String.trim_leading(to_string(entry), "+") == normalized
      end)
    else
      false
    end
  end

  @doc "Returns true if jid matches the bot's own JID (self-chat)."
  def self_chat?(config, jid) do
    own_jid = config[:own_jid] || config["own_jid"]
    is_binary(own_jid) and own_jid == jid
  end
end

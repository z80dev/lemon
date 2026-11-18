defmodule LemonAutomation.CronDelivery do
  @moduledoc """
  Resolves automation supervision targets. Channels owns rendering and delivery.

  Target resolution, in order:

  1. `deliver_to: "none"` - no channel delivery.
  2. An explicit `deliver_to` target - `"telegram:<chat_id>[:<thread_id>]"` or
     `"discord:<channel_id>[:<thread_id>]"`.
  3. The originating chat, when the job's session key is a channel-peer key of
     a registered chat platform (Telegram, Discord, ...). Sub-session suffixes
     are dropped; topics/threads are kept.
  4. The paired owner chat: the first `gateway.telegram.allowed_chat_ids`
     entry when Telegram is enabled, otherwise Discord's
     `gateway.discord.default_channel_id` when Discord is enabled.
  5. Nowhere, when no owner chat is configured.

  So an agent job created from the TUI, web UI, CLI, or any other non-chat
  session reaches the owner's phone without the job naming a target. Operator
  command jobs (`command:` instead of `prompt:`) are delivered only when they
  name an explicit `deliver_to` target.
  """

  alias LemonAutomation.CronJob
  alias LemonCore.{GatewayConfig, SessionKey}

  @type target :: %{
          channel_id: String.t(),
          account_id: String.t(),
          peer: %{kind: atom(), id: String.t(), thread_id: String.t() | nil}
        }

  @explicit_channels ~w(telegram discord)

  @doc """
  Normalizes a `deliver_to` value for storage.

  `nil`, `""` and `"auto"` mean the default resolution; `"none"` opts out;
  anything else must be an explicit target.
  """
  @spec validate(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def validate(nil), do: {:ok, nil}

  def validate(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, nil}

      trimmed ->
        case String.downcase(trimmed) do
          "auto" -> {:ok, nil}
          "none" -> {:ok, "none"}
          _ -> validate_explicit(trimmed)
        end
    end
  end

  def validate(_value),
    do: {:error, "deliver_to must be a string such as \"none\" or \"telegram:<chat_id>\""}

  @doc """
  Resolves the delivery target for a job's run. `session_key` is the key the
  run was created under (the job's session key).
  """
  @spec target(CronJob.t() | nil, String.t() | nil) :: {:ok, target()} | :none
  def target(%CronJob{deliver_to: "none"}, _session_key), do: :none

  def target(%CronJob{deliver_to: deliver_to}, session_key)
      when is_binary(deliver_to) and deliver_to != "" do
    target_for(deliver_to, session_key)
  end

  def target(%CronJob{} = job, session_key) do
    case CronJob.execution_mode(job) do
      :agent -> origin_or_owner(session_key)
      :command -> :none
    end
  end

  def target(nil, session_key), do: origin_or_owner(session_key)

  @doc """
  The paired owner chat, or `:none` when no chat platform is paired.
  """
  @spec owner_target() :: {:ok, target()} | :none
  def owner_target do
    case telegram_owner() do
      {:ok, _} = ok -> ok
      :none -> discord_owner()
    end
  end

  @doc "Resolve the shared explicit/auto/none automation supervision target grammar."
  @spec target_for(String.t() | nil, String.t() | nil) :: {:ok, target()} | :none
  def target_for(value, session_key) when value in [nil, "", "auto"],
    do: origin_or_owner(session_key)

  def target_for("none", _session_key), do: :none

  def target_for(value, _session_key) do
    case parse_explicit(value) do
      {:ok, target} -> {:ok, target}
      :error -> :none
    end
  end

  # ---------------------------------------------------------------------------

  defp origin_or_owner(session_key) do
    case origin_target(session_key) do
      {:ok, _} = ok -> ok
      :none -> owner_target()
    end
  end

  defp origin_target(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{kind: :channel_peer, channel_id: channel_id} = parsed ->
        # A key holding hashed routing ids is not a delivery address; fall back.
        if channel_id in chat_channel_ids() and not SessionKey.opaque_routing?(parsed) do
          {:ok,
           %{
             channel_id: channel_id,
             account_id: parsed.account_id || "default",
             peer: %{kind: parsed.peer_kind, id: parsed.peer_id, thread_id: parsed.thread_id}
           }}
        else
          :none
        end

      _ ->
        :none
    end
  end

  defp origin_target(_session_key), do: :none

  defp chat_channel_ids do
    Enum.map(LemonCore.Config.Gateway.Channel.ids(), &Atom.to_string/1)
  end

  defp validate_explicit(value) do
    case parse_explicit(value) do
      {:ok, _target} ->
        {:ok, value}

      :error ->
        {:error,
         "deliver_to must be \"none\", \"telegram:<chat_id>[:<thread_id>]\", or " <>
           "\"discord:<channel_id>[:<thread_id>]\""}
    end
  end

  defp parse_explicit(value) do
    case String.split(value, ":", parts: 3) do
      [channel, id] -> explicit_target(channel, id, nil)
      [channel, id, thread_id] -> explicit_target(channel, id, thread_id)
      _ -> :error
    end
  end

  defp explicit_target(channel, id, thread_id) do
    channel = String.downcase(channel)

    with true <- channel in @explicit_channels,
         {int_id, ""} <- Integer.parse(id),
         :ok <- valid_thread(thread_id) do
      {:ok,
       %{
         channel_id: channel,
         account_id: account_id(channel),
         peer: %{
           kind: peer_kind(channel, int_id),
           id: Integer.to_string(int_id),
           thread_id: thread_id
         }
       }}
    else
      _ -> :error
    end
  end

  defp valid_thread(nil), do: :ok

  defp valid_thread(thread_id) do
    case Integer.parse(thread_id) do
      {_int, ""} -> :ok
      _ -> :error
    end
  end

  defp telegram_owner do
    with true <- gateway(:enable_telegram) == true,
         section when is_map(section) <- gateway(:telegram),
         [chat_id | _] <- section |> field(:allowed_chat_ids) |> chat_ids() do
      {:ok,
       %{
         channel_id: "telegram",
         account_id: account_id("telegram"),
         peer: %{
           kind: peer_kind("telegram", chat_id),
           id: Integer.to_string(chat_id),
           thread_id: nil
         }
       }}
    else
      _ -> :none
    end
  end

  defp discord_owner do
    with true <- gateway(:enable_discord) == true,
         section when is_map(section) <- gateway(:discord),
         channel_id when is_integer(channel_id) <-
           section |> field(:default_channel_id) |> to_int() do
      thread_id = section |> field(:default_thread_id) |> to_int()

      {:ok,
       %{
         channel_id: "discord",
         account_id: account_id("discord"),
         peer: %{
           kind: :group,
           id: Integer.to_string(channel_id),
           thread_id: if(thread_id, do: Integer.to_string(thread_id))
         }
       }}
    else
      _ -> :none
    end
  end

  defp account_id("telegram"), do: section_string(:telegram, :account_id) || "default"
  defp account_id("discord"), do: section_string(:discord, :default_account_id) || "default"

  defp section_string(section, key) do
    case gateway(section) do
      map when is_map(map) ->
        case field(map, key) do
          value when is_binary(value) and value != "" -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp peer_kind("telegram", chat_id) when chat_id < 0, do: :group
  defp peer_kind("telegram", _chat_id), do: :dm
  defp peer_kind("discord", _channel_id), do: :group

  defp chat_ids(ids) when is_list(ids), do: ids |> Enum.map(&to_int/1) |> Enum.reject(&is_nil/1)
  defp chat_ids(_ids), do: []

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp to_int(_value), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  # Same source order as `LemonChannels.GatewayConfig`: a full-replacement
  # config held by the running gateway wins over the canonical TOML config.
  defp gateway(key) do
    case LemonCore.EngineInfoBridge.gateway_config() do
      {:ok, config} -> GatewayConfig.fetch(config, key, nil)
      :none -> GatewayConfig.get(key, nil)
    end
  rescue
    _ -> nil
  end
end

defmodule LemonChannels.Adapters.Discord.Config do
  @moduledoc """
  Resolution and validation of the `[gateway.discord]` config section.

  Registered under `config :lemon_core, :gateway_channels`, so
  `LemonCore.Config.Gateway` never names Discord: this module owns the section,
  the `enable_discord` flag, the `LEMON_GATEWAY_ENABLE_DISCORD` variable
  declared in `LemonChannels.Env`, and the section's validation rules. See
  `LemonCore.Config.Gateway.Channel`.

  Unlike Telegram's section this one is an explicit field list: unset keys are
  dropped rather than passed through, because the adapter distinguishes
  "absent" from "nil".
  """

  @behaviour LemonCore.Config.Gateway.Channel

  import LemonChannels.Adapters.ConfigHelpers

  alias LemonCore.Config.Validator
  alias LemonCore.Env

  @impl LemonCore.Config.Gateway.Channel
  def id, do: :discord

  @impl LemonCore.Config.Gateway.Channel
  def enabled?(configured) do
    Env.get(:lemon_gateway_enable_discord, default: configured)
  end

  @impl LemonCore.Config.Gateway.Channel
  def resolve(section) when is_map(section) do
    reject_nils(%{
      bot_token: blank_to_nil(section["bot_token"]),
      bot_token_secret: blank_to_nil(section["bot_token_secret"]),
      default_account_id: blank_to_nil(section["default_account_id"]),
      default_channel_id: blank_to_nil_or_integer(section["default_channel_id"]),
      default_thread_id: blank_to_nil_or_integer(section["default_thread_id"]),
      allowed_guild_ids: section["allowed_guild_ids"],
      allowed_channel_ids: section["allowed_channel_ids"],
      deny_unbound_channels: boolean(section["deny_unbound_channels"], false),
      message_content_intent_enabled: boolean(section["message_content_intent_enabled"], false),
      files: section["files"]
    })
  end

  def resolve(_section), do: resolve(%{})

  @impl LemonCore.Config.Gateway.Channel
  def validate(section, errors) when is_map(section) do
    errors
    |> validate_bot_token(Map.get(section, :bot_token))
    |> validate_id_list(
      Map.get(section, :allowed_guild_ids),
      "gateway.discord.allowed_guild_ids"
    )
    |> validate_id_list(
      Map.get(section, :allowed_channel_ids),
      "gateway.discord.allowed_channel_ids"
    )
    |> Validator.validate_boolean(
      Map.get(section, :deny_unbound_channels),
      "gateway.discord.deny_unbound_channels"
    )
    |> Validator.validate_boolean(
      Map.get(section, :message_content_intent_enabled),
      "gateway.discord.message_content_intent_enabled"
    )
  end

  def validate(_section, errors), do: ["gateway.discord: must be a map" | errors]

  defp validate_bot_token(errors, nil), do: errors

  defp validate_bot_token(errors, token) when is_binary(token) do
    cond do
      Validator.env_var_reference?(token) ->
        errors

      valid_token_format?(token) ->
        errors

      true ->
        ["gateway.discord.bot_token: invalid format (expected Discord bot token format)" | errors]
    end
  end

  defp validate_bot_token(errors, _token),
    do: ["gateway.discord.bot_token: must be a string" | errors]

  defp valid_token_format?(token) do
    case String.split(token, ".") do
      [user_id, timestamp, signature] ->
        String.length(user_id) >= 10 and
          String.length(timestamp) >= 5 and
          String.length(signature) >= 5

      _ ->
        false
    end
  end

  defp validate_id_list(errors, nil, _path), do: errors

  defp validate_id_list(errors, ids, path) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1) do
      errors
    else
      ["#{path}: must be a list of integers (Discord snowflake IDs)" | errors]
    end
  end

  defp validate_id_list(errors, _ids, path) do
    ["#{path}: must be a list of integers" | errors]
  end
end

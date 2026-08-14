defmodule LemonChannels.Adapters.Telegram.Config do
  @moduledoc """
  Resolution and validation of the `[gateway.telegram]` config section.

  Registered under `config :lemon_core, :gateway_channels`, so
  `LemonCore.Config.Gateway` never names Telegram: this module owns the
  section, the `enable_telegram` flag, the `LEMON_TELEGRAM_COMPACTION_*`
  variables declared in `LemonChannels.Env`, and the section's validation
  rules. See `LemonCore.Config.Gateway.Channel`.

  Unknown keys pass through atomized, so the transport keeps seeing
  `allowed_chat_ids`, `poll_interval_ms`, `debounce_ms`, `deny_unbound_chats`
  and friends without this module having to enumerate them.

  `bot_token` accepts a literal token or a `"${VAR}"` reference, which is
  expanded here so every reader sees the value rather than the reference.
  """

  @behaviour LemonCore.Config.Gateway.Channel

  import LemonChannels.Adapters.ConfigHelpers

  alias LemonCore.Config.Validator
  alias LemonCore.Env

  @impl LemonCore.Config.Gateway.Channel
  def id, do: :telegram

  @impl LemonCore.Config.Gateway.Channel
  def enabled?(configured) do
    Env.get(:lemon_gateway_enable_telegram, default: configured)
  end

  @impl LemonCore.Config.Gateway.Channel
  def resolve(section) when is_map(section) do
    section
    |> atomize_keys()
    |> Map.merge(%{
      bot_token: bot_token(section),
      bot_token_secret: blank_to_nil(section["bot_token_secret"]),
      compaction: compaction(section)
    })
  end

  def resolve(_section), do: resolve(%{})

  @impl LemonCore.Config.Gateway.Channel
  def validate(section, errors) when is_map(section) do
    errors
    |> validate_bot_token(Map.get(section, :bot_token))
    |> validate_compaction(Map.get(section, :compaction))
  end

  def validate(_section, errors), do: ["gateway.telegram: must be a map" | errors]

  defp bot_token(section) do
    token = section["bot_token"] || section["token"]

    cond do
      is_nil(token) ->
        nil

      is_binary(token) and String.starts_with?(token, "${") and String.ends_with?(token, "}") ->
        token |> String.slice(2..-2//1) |> Env.string()

      true ->
        token
    end
  end

  defp compaction(section) do
    compaction = section["compaction"] || %{}

    %{
      enabled:
        Env.get(:lemon_telegram_compaction_enabled,
          default: if(is_nil(compaction["enabled"]), do: true, else: compaction["enabled"])
        ),
      context_window_tokens:
        Env.get(:lemon_telegram_compaction_context_window,
          default: compaction["context_window_tokens"] || 400_000
        ),
      reserve_tokens:
        Env.get(:lemon_telegram_compaction_reserve_tokens,
          default: compaction["reserve_tokens"] || 16_384
        ),
      trigger_ratio:
        Env.get(:lemon_telegram_compaction_trigger_ratio,
          default: compaction["trigger_ratio"] || 0.9
        )
    }
  end

  defp validate_bot_token(errors, nil), do: errors

  defp validate_bot_token(errors, token) when is_binary(token) do
    cond do
      Validator.env_var_reference?(token) ->
        errors

      Regex.match?(~r/^\d+:[A-Za-z0-9_-]+$/, token) ->
        errors

      true ->
        [
          "gateway.telegram.bot_token: invalid format (expected '123456789:ABCdef...')"
          | errors
        ]
    end
  end

  defp validate_bot_token(errors, _token),
    do: ["gateway.telegram.bot_token: must be a string" | errors]

  defp validate_compaction(errors, nil), do: errors

  defp validate_compaction(errors, compaction) when is_map(compaction) do
    errors
    |> Validator.validate_boolean(
      Map.get(compaction, :enabled),
      "gateway.telegram.compaction.enabled"
    )
    |> Validator.validate_positive_integer(
      Map.get(compaction, :context_window_tokens),
      "gateway.telegram.compaction.context_window_tokens"
    )
    |> Validator.validate_positive_integer(
      Map.get(compaction, :reserve_tokens),
      "gateway.telegram.compaction.reserve_tokens"
    )
    |> Validator.validate_ratio(
      Map.get(compaction, :trigger_ratio),
      "gateway.telegram.compaction.trigger_ratio"
    )
  end

  defp validate_compaction(errors, _compaction),
    do: ["gateway.telegram.compaction: must be a map" | errors]
end

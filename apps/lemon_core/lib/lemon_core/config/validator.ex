defmodule LemonCore.Config.Validator do
  @moduledoc """
  Validation utilities for Lemon configuration.

  Provides functions to validate configuration values and return detailed
  error messages for invalid configurations.

  ## Usage

      config = LemonCore.Config.Modular.load()
      case LemonCore.Config.Validator.validate(config) do
        :ok -> config
        {:error, errors} -> handle_errors(errors)
      end

  ## Validation Rules

  - Agent: valid model names, provider names
  - Gateway: valid port numbers, boolean flags
  - Telegram: token format, compaction settings
  - Discord: token format, guild/channel IDs
  - Web Dashboard: port, host, secret key base, access token
  - Farcaster: hub URL, signer key, app key, frame URL, state secret
  - XMTP: wallet key, environment, API URL, max connections
  - Logging: valid log levels, writable paths
  - Providers: valid API key formats
  - Tools: valid timeout values
  - TUI: valid theme names
  """

  alias LemonCore.Config.Modular

  @valid_log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @valid_themes [:default, :dark, :light, :high_contrast, :lemon]

  @doc """
  Validates a complete modular configuration.

  Returns `:ok` if valid, or `{:error, errors}` with a list of validation errors.

  ## Examples

      iex> Validator.validate(config)
      :ok

      iex> Validator.validate(invalid_config)
      {:error, [
        "agent.default_model: cannot be empty",
        "gateway.web_port: must be between 1 and 65535"
      ]}
  """
  @spec validate(Modular.t() | LemonCore.Config.t()) :: :ok | {:error, [String.t()]}
  def validate(%Modular{} = config) do
    errors = []
    errors = validate_agent(config.agent, errors)
    errors = validate_gateway(config.gateway, errors)
    errors = validate_logging(config.logging, errors)
    errors = validate_providers(config.providers, errors)
    errors = validate_tools(config.tools, errors)
    errors = validate_tui(config.tui, errors)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  def validate(%LemonCore.Config{} = config) do
    # Convert legacy config to modular format for validation
    # Note: legacy config has no 'tools' field
    errors = []
    errors = validate_agent(config.agent, errors)
    errors = validate_gateway(config.gateway, errors)
    errors = validate_logging(config.logging, errors)
    errors = validate_legacy_providers(config.providers, errors)
    errors = validate_tui(config.tui, errors)

    case errors do
      [] -> :ok
      _ -> {:error, Enum.reverse(errors)}
    end
  end

  @doc """
  Validates agent configuration.
  """
  @spec validate_agent(map(), [String.t()]) :: [String.t()]
  def validate_agent(agent, errors) do
    errors
    |> validate_non_empty_string(Map.get(agent, :default_model), "agent.default_model")
    |> validate_non_empty_string(Map.get(agent, :default_provider), "agent.default_provider")
    |> validate_non_empty_string(Map.get(agent, :default_thinking_level), "agent.default_thinking_level")
  end

  @doc """
  Validates gateway configuration.
  """
  @spec validate_gateway(map(), [String.t()]) :: [String.t()]
  def validate_gateway(gateway, errors) do
    errors
    |> validate_positive_integer(Map.get(gateway, :max_concurrent_runs), "gateway.max_concurrent_runs")
    |> validate_boolean(Map.get(gateway, :auto_resume), "gateway.auto_resume")
    |> validate_boolean(Map.get(gateway, :enable_telegram), "gateway.enable_telegram")
    |> validate_boolean(Map.get(gateway, :enable_discord), "gateway.enable_discord")
    |> validate_boolean(Map.get(gateway, :enable_web_dashboard), "gateway.enable_web_dashboard")
    |> validate_boolean(Map.get(gateway, :enable_farcaster), "gateway.enable_farcaster")
    |> validate_boolean(Map.get(gateway, :enable_xmtp), "gateway.enable_xmtp")
    |> validate_boolean(Map.get(gateway, :require_engine_lock), "gateway.require_engine_lock")
    |> validate_non_negative_integer(Map.get(gateway, :engine_lock_timeout_ms), "gateway.engine_lock_timeout_ms")
    |> validate_telegram_config(Map.get(gateway, :telegram))
    |> validate_discord_config(Map.get(gateway, :discord))
    |> validate_web_dashboard_config(Map.get(gateway, :web_dashboard))
    |> validate_farcaster_config(Map.get(gateway, :farcaster))
    |> validate_xmtp_config(Map.get(gateway, :xmtp))
    |> validate_queue_config(Map.get(gateway, :queue))
  end

  @doc """
  Validates Telegram configuration.
  """
  @spec validate_telegram_config([String.t()], map() | nil) :: [String.t()]
  def validate_telegram_config(errors, nil), do: errors

  def validate_telegram_config(errors, telegram) when is_map(telegram) do
    errors
    |> validate_telegram_token(Map.get(telegram, :token))
    |> validate_telegram_compaction(Map.get(telegram, :compaction))
  end

  def validate_telegram_config(errors, _),
    do: ["gateway.telegram: must be a map" | errors]

  defp validate_telegram_token(errors, nil), do: errors

  defp validate_telegram_token(errors, token) when is_binary(token) do
    if String.starts_with?(token, "${") and String.ends_with?(token, "}") do
      # Token references an env var, which is valid
      errors
    else
      # Basic Telegram bot token format validation
      # Format: 123456789:ABCdefGHIjklMNOpqrsTUVwxyz
      if Regex.match?(~r/^\d+:[A-Za-z0-9_-]+$/, token) do
        errors
      else
        ["gateway.telegram.token: invalid format (expected '123456789:ABCdef...')" | errors]
      end
    end
  end

  defp validate_telegram_token(errors, _), do: ["gateway.telegram.token: must be a string" | errors]

  defp validate_telegram_compaction(errors, nil), do: errors

  defp validate_telegram_compaction(errors, compaction) when is_map(compaction) do
    errors
    |> validate_boolean(Map.get(compaction, :enabled), "gateway.telegram.compaction.enabled")
    |> validate_positive_integer(Map.get(compaction, :context_window_tokens), "gateway.telegram.compaction.context_window_tokens")
    |> validate_positive_integer(Map.get(compaction, :reserve_tokens), "gateway.telegram.compaction.reserve_tokens")
    |> validate_ratio(Map.get(compaction, :trigger_ratio), "gateway.telegram.compaction.trigger_ratio")
  end

  defp validate_telegram_compaction(errors, _),
    do: ["gateway.telegram.compaction: must be a map" | errors]

  @doc """
  Validates Discord configuration.
  """
  @spec validate_discord_config([String.t()], map() | nil) :: [String.t()]
  def validate_discord_config(errors, nil), do: errors

  def validate_discord_config(errors, discord) when is_map(discord) do
    errors
    |> validate_discord_token(Map.get(discord, :bot_token))
    |> validate_discord_id_list(Map.get(discord, :allowed_guild_ids), "gateway.discord.allowed_guild_ids")
    |> validate_discord_id_list(Map.get(discord, :allowed_channel_ids), "gateway.discord.allowed_channel_ids")
    |> validate_boolean(Map.get(discord, :deny_unbound_channels), "gateway.discord.deny_unbound_channels")
  end

  def validate_discord_config(errors, _),
    do: ["gateway.discord: must be a map" | errors]

  defp validate_discord_token(errors, nil), do: errors

  defp validate_discord_token(errors, token) when is_binary(token) do
    if String.starts_with?(token, "${") and String.ends_with?(token, "}") do
      # Token references an env var, which is valid
      errors
    else
      # Basic Discord bot token format validation
      # Discord tokens are base64-encoded and typically have 3 parts separated by dots
      # Format: XXXXXX.YYYYYY.ZZZZZZ (where each part is base64url encoded)
      parts = String.split(token, ".")

      # Discord tokens have 3 parts, each part should be reasonably long
      # The user ID part (first) is typically 17-20 digits
      # The timestamp part (second) is base64 encoded
      # The signature part (third) is base64 encoded
      if length(parts) == 3 do
        [user_id, timestamp, signature] = parts

        if String.length(user_id) >= 10 and
             String.length(timestamp) >= 5 and
             String.length(signature) >= 5 do
          errors
        else
          ["gateway.discord.bot_token: invalid format (expected Discord bot token format)" | errors]
        end
      else
        ["gateway.discord.bot_token: invalid format (expected Discord bot token format)" | errors]
      end
    end
  end

  defp validate_discord_token(errors, _), do: ["gateway.discord.bot_token: must be a string" | errors]

  defp validate_discord_id_list(errors, nil, _path), do: errors

  defp validate_discord_id_list(errors, ids, path) when is_list(ids) do
    if Enum.all?(ids, &is_integer/1) do
      errors
    else
      ["#{path}: must be a list of integers (Discord snowflake IDs)" | errors]
    end
  end

  defp validate_discord_id_list(errors, _ids, path) do
    ["#{path}: must be a list of integers" | errors]
  end

  @doc """
  Validates Web Dashboard configuration.
  """
  @spec validate_web_dashboard_config([String.t()], map() | nil) :: [String.t()]
  def validate_web_dashboard_config(errors, nil), do: errors

  def validate_web_dashboard_config(errors, web_dashboard) when is_map(web_dashboard) do
    errors
    |> validate_web_dashboard_port(Map.get(web_dashboard, :port))
    |> validate_web_dashboard_host(Map.get(web_dashboard, :host))
    |> validate_web_dashboard_secret_key_base(Map.get(web_dashboard, :secret_key_base))
    |> validate_web_dashboard_access_token(Map.get(web_dashboard, :access_token))
  end

  def validate_web_dashboard_config(errors, _),
    do: ["gateway.web_dashboard: must be a map" | errors]

  defp validate_web_dashboard_port(errors, nil), do: errors

  defp validate_web_dashboard_port(errors, port) when is_integer(port) do
    if port > 0 and port <= 65535 do
      errors
    else
      ["gateway.web_dashboard.port: must be between 1 and 65535" | errors]
    end
  end

  defp validate_web_dashboard_port(errors, _), do: ["gateway.web_dashboard.port: must be an integer" | errors]

  defp validate_web_dashboard_host(errors, nil), do: errors

  defp validate_web_dashboard_host(errors, host) when is_binary(host) do
    if String.trim(host) == "" do
      ["gateway.web_dashboard.host: cannot be empty" | errors]
    else
      errors
    end
  end

  defp validate_web_dashboard_host(errors, _), do: ["gateway.web_dashboard.host: must be a string" | errors]

  defp validate_web_dashboard_secret_key_base(errors, nil), do: errors

  defp validate_web_dashboard_secret_key_base(errors, key) when is_binary(key) do
    if String.starts_with?(key, "${") and String.ends_with?(key, "}") do
      # References an env var, which is valid
      errors
    else
      # Secret key base should be at least 64 characters for security
      if String.length(key) >= 64 do
        errors
      else
        ["gateway.web_dashboard.secret_key_base: must be at least 64 characters (use LEMON_WEB_SECRET_KEY_BASE env var)" | errors]
      end
    end
  end

  defp validate_web_dashboard_secret_key_base(errors, _), do: ["gateway.web_dashboard.secret_key_base: must be a string" | errors]

  defp validate_web_dashboard_access_token(errors, nil), do: errors

  defp validate_web_dashboard_access_token(errors, token) when is_binary(token) do
    if String.starts_with?(token, "${") and String.ends_with?(token, "}") do
      # References an env var, which is valid
      errors
    else
      # Access token should be reasonably strong (at least 16 characters)
      if String.length(token) >= 16 do
        errors
      else
        ["gateway.web_dashboard.access_token: should be at least 16 characters for security" | errors]
      end
    end
  end

  defp validate_web_dashboard_access_token(errors, _), do: ["gateway.web_dashboard.access_token: must be a string" | errors]

  @doc """
  Validates Farcaster configuration.
  """
  @spec validate_farcaster_config([String.t()], map() | nil) :: [String.t()]
  def validate_farcaster_config(errors, nil), do: errors

  def validate_farcaster_config(errors, farcaster) when is_map(farcaster) do
    errors
    |> validate_farcaster_hub_url(Map.get(farcaster, :hub_url))
    |> validate_farcaster_signer_key(Map.get(farcaster, :signer_key))
    |> validate_farcaster_app_key(Map.get(farcaster, :app_key))
    |> validate_farcaster_frame_url(Map.get(farcaster, :frame_url))
    |> validate_boolean(Map.get(farcaster, :verify_trusted_data), "gateway.farcaster.verify_trusted_data")
    |> validate_farcaster_state_secret(Map.get(farcaster, :state_secret))
  end

  def validate_farcaster_config(errors, _),
    do: ["gateway.farcaster: must be a map" | errors]

  defp validate_farcaster_hub_url(errors, nil), do: errors

  defp validate_farcaster_hub_url(errors, url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      errors
    else
      ["gateway.farcaster.hub_url: must start with http:// or https://" | errors]
    end
  end

  defp validate_farcaster_hub_url(errors, _), do: ["gateway.farcaster.hub_url: must be a string" | errors]

  defp validate_farcaster_signer_key(errors, nil), do: errors

  defp validate_farcaster_signer_key(errors, key) when is_binary(key) do
    if String.starts_with?(key, "${") and String.ends_with?(key, "}") do
      # References an env var, which is valid
      errors
    else
      # Farcaster signer keys are hex-encoded ed25519 private keys (64 hex chars)
      if Regex.match?(~r/^[0-9a-fA-F]{64}$/, key) do
        errors
      else
        ["gateway.farcaster.signer_key: invalid format (expected 64-character hex string)" | errors]
      end
    end
  end

  defp validate_farcaster_signer_key(errors, _), do: ["gateway.farcaster.signer_key: must be a string" | errors]

  defp validate_farcaster_app_key(errors, nil), do: errors

  defp validate_farcaster_app_key(errors, key) when is_binary(key) do
    if String.starts_with?(key, "${") and String.ends_with?(key, "}") do
      # References an env var, which is valid
      errors
    else
      # Farcaster app keys are typically UUIDs or similar identifiers
      if String.length(key) >= 8 do
        errors
      else
        ["gateway.farcaster.app_key: must be at least 8 characters" | errors]
      end
    end
  end

  defp validate_farcaster_app_key(errors, _), do: ["gateway.farcaster.app_key: must be a string" | errors]

  defp validate_farcaster_frame_url(errors, nil), do: errors

  defp validate_farcaster_frame_url(errors, url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      errors
    else
      ["gateway.farcaster.frame_url: must start with http:// or https://" | errors]
    end
  end

  defp validate_farcaster_frame_url(errors, _), do: ["gateway.farcaster.frame_url: must be a string" | errors]

  defp validate_farcaster_state_secret(errors, nil), do: errors

  defp validate_farcaster_state_secret(errors, secret) when is_binary(secret) do
    if String.starts_with?(secret, "${") and String.ends_with?(secret, "}") do
      # References an env var, which is valid
      errors
    else
      # State secret should be reasonably strong (at least 32 characters)
      if String.length(secret) >= 32 do
        errors
      else
        ["gateway.farcaster.state_secret: must be at least 32 characters for security" | errors]
      end
    end
  end

  defp validate_farcaster_state_secret(errors, _), do: ["gateway.farcaster.state_secret: must be a string" | errors]

  @doc """
  Validates XMTP configuration.
  """
  @spec validate_xmtp_config([String.t()], map() | nil) :: [String.t()]
  def validate_xmtp_config(errors, nil), do: errors

  def validate_xmtp_config(errors, xmtp) when is_map(xmtp) do
    errors
    |> validate_xmtp_wallet_key(Map.get(xmtp, :wallet_key))
    |> validate_xmtp_environment(Map.get(xmtp, :environment))
    |> validate_xmtp_api_url(Map.get(xmtp, :api_url))
    |> validate_positive_integer(Map.get(xmtp, :max_connections), "gateway.xmtp.max_connections")
    |> validate_boolean(Map.get(xmtp, :enable_relay), "gateway.xmtp.enable_relay")
  end

  def validate_xmtp_config(errors, _),
    do: ["gateway.xmtp: must be a map" | errors]

  defp validate_xmtp_wallet_key(errors, nil), do: errors

  defp validate_xmtp_wallet_key(errors, key) when is_binary(key) do
    if String.starts_with?(key, "${") and String.ends_with?(key, "}") do
      # References an env var, which is valid
      errors
    else
      # XMTP wallet keys are Ethereum private keys (64 hex characters, with or without 0x prefix)
      # Remove 0x prefix if present
      key_without_prefix = String.replace_prefix(key, "0x", "")

      if Regex.match?(~r/^[0-9a-fA-F]{64}$/, key_without_prefix) do
        errors
      else
        ["gateway.xmtp.wallet_key: invalid format (expected 64-character hex string, optionally with 0x prefix)" | errors]
      end
    end
  end

  defp validate_xmtp_wallet_key(errors, _), do: ["gateway.xmtp.wallet_key: must be a string" | errors]

  defp validate_xmtp_environment(errors, nil), do: errors

  defp validate_xmtp_environment(errors, env) when is_binary(env) do
    valid_envs = ["production", "dev", "local"]

    if env in valid_envs do
      errors
    else
      ["gateway.xmtp.environment: invalid environment '#{env}'. Valid: #{Enum.join(valid_envs, ", ")}" | errors]
    end
  end

  defp validate_xmtp_environment(errors, _), do: ["gateway.xmtp.environment: must be a string" | errors]

  defp validate_xmtp_api_url(errors, nil), do: errors

  defp validate_xmtp_api_url(errors, url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      errors
    else
      ["gateway.xmtp.api_url: must start with http:// or https://" | errors]
    end
  end

  defp validate_xmtp_api_url(errors, _), do: ["gateway.xmtp.api_url: must be a string" | errors]

  @doc """
  Validates queue configuration.
  """
  @spec validate_queue_config([String.t()], map() | nil) :: [String.t()]
  def validate_queue_config(errors, nil), do: errors

  def validate_queue_config(errors, queue) when is_map(queue) do
    errors
    |> validate_queue_mode(Map.get(queue, :mode))
    |> validate_optional_positive_integer(Map.get(queue, :cap), "gateway.queue.cap")
    |> validate_queue_drop(Map.get(queue, :drop))
  end

  def validate_queue_config(errors, _), do: ["gateway.queue: must be a map" | errors]

  defp validate_queue_mode(errors, nil), do: errors

  defp validate_queue_mode(errors, mode) when is_binary(mode) do
    valid_modes = ["fifo", "lifo", "priority"]

    if mode in valid_modes do
      errors
    else
      ["gateway.queue.mode: invalid mode '#{mode}'. Valid: #{Enum.join(valid_modes, ", ")}" | errors]
    end
  end

  defp validate_queue_mode(errors, _), do: ["gateway.queue.mode: must be a string" | errors]

  defp validate_queue_drop(errors, nil), do: errors

  defp validate_queue_drop(errors, drop) when is_binary(drop) do
    valid_drops = ["oldest", "newest", "reject"]

    if drop in valid_drops do
      errors
    else
      ["gateway.queue.drop: invalid drop policy '#{drop}'. Valid: #{Enum.join(valid_drops, ", ")}" | errors]
    end
  end

  defp validate_queue_drop(errors, _), do: ["gateway.queue.drop: must be a string" | errors]

  @doc """
  Validates logging configuration.
  """
  @spec validate_logging(map(), [String.t()]) :: [String.t()]
  def validate_logging(logging, errors) do
    errors
    |> validate_log_level(Map.get(logging, :level), "logging.level")
    |> validate_optional_path(Map.get(logging, :file), "logging.file")
    |> validate_positive_integer(Map.get(logging, :max_no_bytes), "logging.max_no_bytes")
    |> validate_positive_integer(Map.get(logging, :max_no_files), "logging.max_no_files")
    |> validate_boolean(Map.get(logging, :compress_on_rotate), "logging.compress_on_rotate")
  end

  @doc """
  Validates providers configuration.
  """
  @spec validate_providers(map(), [String.t()]) :: [String.t()]
  def validate_providers(providers, errors) do
    errors
    |> validate_providers_map(Map.get(providers, :providers))
  end

  @doc """
  Validates tools configuration.
  """
  @spec validate_tools(map(), [String.t()]) :: [String.t()]
  def validate_tools(tools, errors) do
    errors
    |> validate_boolean(Map.get(tools, :auto_resize_images), "tools.auto_resize_images")
  end

  @doc """
  Validates TUI configuration.
  """
  @spec validate_tui(map(), [String.t()]) :: [String.t()]
  def validate_tui(tui, errors) do
    errors
    |> validate_theme(Map.get(tui, :theme), "tui.theme")
    |> validate_boolean(Map.get(tui, :debug), "tui.debug")
  end

  # Private validation helpers

  defp validate_non_empty_string(errors, nil, _path) do
    errors
  end

  defp validate_non_empty_string(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      ["#{path}: cannot be empty" | errors]
    else
      errors
    end
  end

  defp validate_non_empty_string(errors, value, path) when is_atom(value) do
    # Atoms are valid for enum-like fields (thinking_level, provider, etc.)
    if value == nil do
      ["#{path}: cannot be nil" | errors]
    else
      errors
    end
  end

  defp validate_non_empty_string(errors, _value, path) do
    ["#{path}: must be a string" | errors]
  end

  defp validate_positive_integer(errors, nil, _path), do: errors

  defp validate_positive_integer(errors, value, path) when is_integer(value) do
    if value > 0 do
      errors
    else
      ["#{path}: must be a positive integer" | errors]
    end
  end

  defp validate_positive_integer(errors, _value, path) do
    ["#{path}: must be a positive integer" | errors]
  end

  defp validate_non_negative_integer(errors, nil, _path), do: errors

  defp validate_non_negative_integer(errors, value, path) when is_integer(value) do
    if value >= 0 do
      errors
    else
      ["#{path}: must be a non-negative integer" | errors]
    end
  end

  defp validate_non_negative_integer(errors, _value, path) do
    ["#{path}: must be a non-negative integer" | errors]
  end

  defp validate_optional_positive_integer(errors, nil, _path), do: errors

  defp validate_optional_positive_integer(errors, value, path) when is_integer(value) do
    if value > 0 do
      errors
    else
      ["#{path}: must be a positive integer" | errors]
    end
  end

  defp validate_optional_positive_integer(errors, _value, path) do
    ["#{path}: must be a positive integer" | errors]
  end

  defp validate_ratio(errors, nil, _path), do: errors

  defp validate_ratio(errors, value, path) when is_float(value) or is_integer(value) do
    if value >= 0.0 and value <= 1.0 do
      errors
    else
      ["#{path}: must be between 0.0 and 1.0" | errors]
    end
  end

  defp validate_ratio(errors, _value, path) do
    ["#{path}: must be a number between 0.0 and 1.0" | errors]
  end

  defp validate_boolean(errors, nil, _path), do: errors

  defp validate_boolean(errors, value, _path) when is_boolean(value), do: errors

  defp validate_boolean(errors, _value, path) do
    ["#{path}: must be a boolean" | errors]
  end

  defp validate_log_level(errors, nil, _path), do: errors

  defp validate_log_level(errors, value, path) when is_atom(value) do
    if value in @valid_log_levels do
      errors
    else
      valid_levels = Enum.join(@valid_log_levels, ", ")
      ["#{path}: invalid level '#{value}'. Valid: #{valid_levels}" | errors]
    end
  end

  defp validate_log_level(errors, value, path) when is_binary(value) do
    atom_value = String.downcase(value) |> String.to_atom()
    validate_log_level(errors, atom_value, path)
  end

  defp validate_log_level(errors, _value, path) do
    ["#{path}: must be a valid log level" | errors]
  end

  defp validate_optional_path(errors, nil, _path), do: errors

  defp validate_optional_path(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      ["#{path}: cannot be empty string" | errors]
    else
      errors
    end
  end

  defp validate_optional_path(errors, _value, path) do
    ["#{path}: must be a string" | errors]
  end

  defp validate_theme(errors, nil, _path), do: errors

  defp validate_theme(errors, value, path) when is_atom(value) do
    if value in @valid_themes do
      errors
    else
      valid_themes = Enum.join(@valid_themes, ", ")
      ["#{path}: invalid theme '#{value}'. Valid: #{valid_themes}" | errors]
    end
  end

  defp validate_theme(errors, value, path) when is_binary(value) do
    atom_value = String.downcase(value) |> String.to_atom()
    validate_theme(errors, atom_value, path)
  end

  defp validate_theme(errors, _value, path) do
    ["#{path}: must be a valid theme" | errors]
  end

  defp validate_providers_map(errors, nil), do: errors

  defp validate_providers_map(errors, providers) when is_map(providers) do
    Enum.reduce(providers, errors, fn {name, config}, acc ->
      validate_provider_config(acc, name, config)
    end)
  end

  defp validate_providers_map(errors, _value) do
    ["providers.providers: must be a map" | errors]
  end

  @doc """
  Validates legacy providers configuration (map format).
  """
  @spec validate_legacy_providers(map(), [String.t()]) :: [String.t()]
  def validate_legacy_providers(providers, errors) when is_map(providers) do
    Enum.reduce(providers, errors, fn {name, config}, acc ->
      validate_legacy_provider_config(acc, name, config)
    end)
  end

  def validate_legacy_providers(_providers, errors), do: errors

  defp validate_legacy_provider_config(errors, name, config) when is_map(config) do
    # Validate API key if present
    errors =
      case Map.get(config, :api_key) do
        nil -> errors
        "" -> ["providers.#{name}.api_key: cannot be empty" | errors]
        _ -> errors
      end

    # Validate base URL if present
    errors =
      case Map.get(config, :base_url) do
        nil -> errors
        "" -> ["providers.#{name}.base_url: cannot be empty" | errors]
        url when is_binary(url) ->
          if String.starts_with?(url, ["http://", "https://"]) do
            errors
          else
            ["providers.#{name}.base_url: must start with http:// or https://" | errors]
          end
        _ -> ["providers.#{name}.base_url: must be a string" | errors]
      end

    errors
  end

  defp validate_legacy_provider_config(errors, name, _config) do
    ["providers.#{name}: must be a map" | errors]
  end

  defp validate_provider_config(errors, name, config) when is_map(config) do
    # Validate API key if present
    errors =
      case Map.get(config, :api_key) do
        nil -> errors
        "" -> ["providers.providers.#{name}.api_key: cannot be empty" | errors]
        _ -> errors
      end

    # Validate base URL if present
    errors =
      case Map.get(config, :base_url) do
        nil -> errors
        "" -> ["providers.providers.#{name}.base_url: cannot be empty" | errors]
        url when is_binary(url) ->
          if String.starts_with?(url, ["http://", "https://"]) do
            errors
          else
            ["providers.providers.#{name}.base_url: must start with http:// or https://" | errors]
          end
        _ -> ["providers.providers.#{name}.base_url: must be a string" | errors]
      end

    errors
  end

  defp validate_provider_config(errors, name, _config) do
    ["providers.providers.#{name}: must be a map" | errors]
  end
end

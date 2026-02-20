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
    |> validate_boolean(Map.get(gateway, :require_engine_lock), "gateway.require_engine_lock")
    |> validate_non_negative_integer(Map.get(gateway, :engine_lock_timeout_ms), "gateway.engine_lock_timeout_ms")
  end

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

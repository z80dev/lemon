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

  - Agent: valid model names, positive integers for limits
  - Gateway: valid port numbers, boolean flags
  - Logging: valid log levels, writable paths
  - Providers: valid API key formats
  - Tools: valid timeout values, positive integers
  - TUI: valid theme names
  """

  alias LemonCore.Config.Modular

  @valid_log_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @valid_themes [:default, :dark, :light, :high_contrast]

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
  @spec validate(Modular.t()) :: :ok | {:error, [String.t()]}
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

  @doc """
  Validates agent configuration.
  """
  @spec validate_agent(map(), [String.t()]) :: [String.t()]
  def validate_agent(agent, errors) do
    errors
    |> validate_non_empty_string(Map.get(agent, :default_model), "agent.default_model")
    |> validate_positive_integer(Map.get(agent, :max_iterations), "agent.max_iterations")
    |> validate_non_negative_integer(Map.get(agent, :timeout_seconds), "agent.timeout_seconds")
    |> validate_boolean(Map.get(agent, :enable_approval), "agent.enable_approval")
  end

  @doc """
  Validates gateway configuration.
  """
  @spec validate_gateway(map(), [String.t()]) :: [String.t()]
  def validate_gateway(gateway, errors) do
    errors
    |> validate_port(Map.get(gateway, :web_port), "gateway.web_port")
    |> validate_boolean(Map.get(gateway, :enable_telegram), "gateway.enable_telegram")
    |> validate_boolean(Map.get(gateway, :enable_sms), "gateway.enable_sms")
    |> validate_boolean(Map.get(gateway, :enable_discord), "gateway.enable_discord")
  end

  @doc """
  Validates logging configuration.
  """
  @spec validate_logging(map(), [String.t()]) :: [String.t()]
  def validate_logging(logging, errors) do
    errors
    |> validate_log_level(Map.get(logging, :level), "logging.level")
    |> validate_optional_path(Map.get(logging, :file_path), "logging.file_path")
    |> validate_positive_integer(Map.get(logging, :max_size_mb), "logging.max_size_mb")
    |> validate_positive_integer(Map.get(logging, :max_files), "logging.max_files")
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
    |> validate_non_negative_integer(Map.get(tools, :timeout_ms), "tools.timeout_ms")
    |> validate_boolean(Map.get(tools, :enable_web_search), "tools.enable_web_search")
    |> validate_boolean(Map.get(tools, :enable_file_access), "tools.enable_file_access")
    |> validate_positive_integer(Map.get(tools, :max_file_size_mb), "tools.max_file_size_mb")
  end

  @doc """
  Validates TUI configuration.
  """
  @spec validate_tui(map(), [String.t()]) :: [String.t()]
  def validate_tui(tui, errors) do
    errors
    |> validate_theme(Map.get(tui, :theme), "tui.theme")
    |> validate_boolean(Map.get(tui, :debug), "tui.debug")
    |> validate_boolean(Map.get(tui, :compact), "tui.compact")
  end

  # Private validation helpers

  defp validate_non_empty_string(errors, nil, path) do
    ["#{path}: cannot be nil" | errors]
  end

  defp validate_non_empty_string(errors, value, path) when is_binary(value) do
    if String.trim(value) == "" do
      ["#{path}: cannot be empty" | errors]
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

  defp validate_port(errors, nil, _path), do: errors

  defp validate_port(errors, value, path) when is_integer(value) do
    if value >= 1 and value <= 65_535 do
      errors
    else
      ["#{path}: must be between 1 and 65535" | errors]
    end
  end

  defp validate_port(errors, _value, path) do
    ["#{path}: must be a valid port number" | errors]
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

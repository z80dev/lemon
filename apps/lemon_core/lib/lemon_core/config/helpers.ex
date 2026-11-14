defmodule LemonCore.Config.Helpers do
  @moduledoc """
  Helper functions for configuration resolution.

  Inspired by Ironclaw's config/helpers.rs, these utilities provide
  consistent environment variable handling with proper type conversion
  and default value support.

  ## Usage

      alias LemonCore.Config.Helpers

      # Get optional env var
      api_key = Helpers.get_env("OPENAI_API_KEY")

      # Get with default
      port = Helpers.get_env_int("PORT", 4000)

      # Parse boolean
      debug = Helpers.get_env_bool("DEBUG", false)
  """

  @doc """
  Gets an optional environment variable.

  Returns `nil` if the variable is not set or is empty.

  ## Examples

      iex> Helpers.get_env("NONEXISTENT_VAR")
      nil

      iex> System.put_env("EXISTING_VAR", "value")
      iex> Helpers.get_env("EXISTING_VAR")
      "value"
  """
  @spec get_env(String.t()) :: String.t() | nil
  def get_env(key) do
    case System.get_env(key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @doc """
  Gets an environment variable with a default value.

  ## Examples

      iex> Helpers.get_env("NONEXISTENT", "default")
      "default"
  """
  @spec get_env(String.t(), String.t()) :: String.t()
  def get_env(key, default) do
    case get_env(key) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Gets an environment variable as an integer.

  Returns the default if the variable is not set, empty, or cannot be parsed.

  ## Examples

      iex> System.put_env("PORT", "8080")
      iex> Helpers.get_env_int("PORT", 4000)
      8080

      iex> Helpers.get_env_int("NONEXISTENT", 4000)
      4000

      iex> System.put_env("BAD_PORT", "not_a_number")
      iex> Helpers.get_env_int("BAD_PORT", 4000)
      4000
  """
  @spec get_env_int(String.t(), integer()) :: integer()
  def get_env_int(key, default) do
    case get_env(key) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> default
        end
    end
  end

  @doc """
  Gets an environment variable as a float.

  Returns the default if the variable is not set, empty, or cannot be parsed.
  """
  @spec get_env_float(String.t(), float()) :: float()
  def get_env_float(key, default) do
    case get_env(key) do
      nil ->
        default

      value ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> default
        end
    end
  end

  @doc """
  Gets an environment variable as a boolean.

  The following values are considered true: "true", "1", "yes", "on"
  The following values are considered false: "false", "0", "no", "off"
  Returns the default if the variable is not set or empty.

  ## Examples

      iex> System.put_env("DEBUG", "true")
      iex> Helpers.get_env_bool("DEBUG", false)
      true

      iex> System.put_env("ENABLED", "1")
      iex> Helpers.get_env_bool("ENABLED", false)
      true

      iex> System.put_env("DISABLED", "no")
      iex> Helpers.get_env_bool("DISABLED", true)
      false
  """
  @spec get_env_bool(String.t(), boolean()) :: boolean()
  def get_env_bool(key, default) do
    case get_env(key) do
      nil ->
        default

      value ->
        normalized = String.downcase(String.trim(value))

        case normalized do
          "true" -> true
          "1" -> true
          "yes" -> true
          "on" -> true
          "false" -> false
          "0" -> false
          "no" -> false
          "off" -> false
          _ -> default
        end
    end
  end

  @doc """
  Gets an environment variable as a list of strings.

  Values are split by the given delimiter (default: ",").
  Empty values are filtered out.

  ## Examples

      iex> System.put_env("ALLOWED_HOSTS", "localhost,example.com")
      iex> Helpers.get_env_list("ALLOWED_HOSTS")
      ["localhost", "example.com"]
  """
  @spec get_env_list(String.t(), String.t()) :: [String.t()]
  def get_env_list(key, delimiter \\ ",") do
    case get_env(key) do
      nil ->
        []

      value ->
        value
        |> String.split(delimiter)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  Gets an environment variable as bytes.

  Supports: B, KB, MB, GB (case insensitive, optional space)
  Returns the default if parsing fails.

  ## Examples

      iex> Helpers.parse_bytes("10MB", 0)
      10485760

      iex> Helpers.parse_bytes("1.5 GB", 0)
      1610612736
  """
  @spec parse_bytes(String.t() | nil, integer()) :: integer()
  def parse_bytes(nil, default), do: default

  def parse_bytes(value, default) when is_binary(value) do
    value = String.trim(value)

    case Regex.run(~r/^([\d.]+)\s*([kmgt]?b)?$/i, value) do
      [_, num_str, unit] ->
        case Float.parse(num_str) do
          {num, ""} ->
            multiplier =
              case String.downcase(unit) do
                "b" -> 1
                "kb" -> 1024
                "mb" -> 1_048_576
                "gb" -> 1_073_741_824
                "tb" -> 1_099_511_627_776
                "" -> 1
                _ -> nil
              end

            if multiplier, do: round(num * multiplier), else: default

          _ ->
            default
        end

      _ ->
        default
    end
  end

  @doc """
  Gets an environment variable as bytes.

  ## Examples

      iex> System.put_env("MAX_SIZE", "10MB")
      iex> Helpers.get_env_bytes("MAX_SIZE", 1024)
      10485760
  """
  @spec get_env_bytes(String.t(), integer()) :: integer()
  def get_env_bytes(key, default) do
    get_env(key) |> parse_bytes(default)
  end
end

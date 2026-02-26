defmodule MarketIntel.Errors do
  @moduledoc """
  Standardized error handling for MarketIntel ingestion modules.
  
  Provides consistent error types and formatting for:
  - External API failures
  - Configuration errors  
  - Data parsing failures
  - Network/timeout issues
  """

  @type error :: {:error, term()}
  @type result(t) :: {:ok, t} | error

  @doc """
  Creates an API error tuple with descriptive message.
  
  ## Examples
  
      iex> Errors.api_error("Polymarket", "HTTP 500")
      {:error, %{type: :api_error, source: "Polymarket", reason: "HTTP 500"}}
  """
  @spec api_error(String.t(), term()) :: error
  def api_error(source, reason) do
    {:error, %{type: :api_error, source: source, reason: format_reason(reason)}}
  end

  @doc """
  Creates a configuration error tuple.
  
  ## Examples
  
      iex> Errors.config_error("missing BASESCAN_KEY")
      {:error, %{type: :config_error, reason: "missing BASESCAN_KEY"}}
  """
  @spec config_error(term()) :: error
  def config_error(reason) do
    {:error, %{type: :config_error, reason: format_reason(reason)}}
  end

  @doc """
  Creates a parse error tuple for JSON/data parsing failures.
  
  ## Examples
  
      iex> Errors.parse_error("invalid JSON")
      {:error, %{type: :parse_error, reason: "invalid JSON"}}
  """
  @spec parse_error(term()) :: error
  def parse_error(reason) do
    {:error, %{type: :parse_error, reason: format_reason(reason)}}
  end

  @doc """
  Creates a network error tuple for timeout/connection issues.
  
  ## Examples
  
      iex> Errors.network_error(:timeout)
      {:error, %{type: :network_error, reason: "timeout"}}
  """
  @spec network_error(term()) :: error
  def network_error(reason) do
    {:error, %{type: :network_error, reason: format_reason(reason)}}
  end

  @doc """
  Formats an error for logging purposes.
  
  ## Examples
  
      iex> Errors.format_for_log({:error, %{type: :api_error, source: "API", reason: "fail"}})
      "API error from API: fail"
  """
  @spec format_for_log(error) :: String.t()
  def format_for_log({:error, %{type: type, source: source, reason: reason}}) do
    "#{format_type(type)} error from #{source}: #{reason}"
  end

  def format_for_log({:error, %{type: type, reason: reason}}) do
    "#{format_type(type)}: #{reason}"
  end

  def format_for_log({:error, reason}) when is_binary(reason) do
    reason
  end

  def format_for_log({:error, reason}) do
    inspect(reason)
  end

  @doc """
  Checks if an error is of a specific type.
  
  ## Examples
  
      iex> error = Errors.api_error("API", "fail")
      iex> Errors.type?(error, :api_error)
      true
  """
  @spec type?(error, atom()) :: boolean()
  def type?({:error, %{type: type}}, expected_type), do: type == expected_type
  def type?(_error, _type), do: false

  @doc """
  Unwraps an error reason from an error tuple.
  
  ## Examples
  
      iex> Errors.unwrap({:error, %{type: :api_error, reason: "fail"}})
      "fail"
  """
  @spec unwrap(error) :: term()
  def unwrap({:error, %{reason: reason}}), do: reason
  def unwrap({:error, reason}), do: reason
  def unwrap(other), do: other

  # Private functions

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp format_type(:api_error), do: "API"
  defp format_type(:config_error), do: "Configuration"
  defp format_type(:parse_error), do: "Parse"
  defp format_type(:network_error), do: "Network"
  defp format_type(type), do: to_string(type)
end

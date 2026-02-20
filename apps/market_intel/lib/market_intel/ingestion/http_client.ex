defmodule MarketIntel.Ingestion.HttpClient do
  @moduledoc """
  HTTP client helper for ingestion modules.
  
  Provides consistent HTTP request handling with standardized error wrapping
  and JSON response parsing.
  """

  require Logger
  alias MarketIntel.Errors

  @type method :: :get | :post
  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type opts :: keyword()
  @type http_result :: {:ok, map()} | Errors.error()

  @default_timeout 15_000
  @default_recv_timeout 30_000

  @doc """
  Makes an HTTP GET request with standardized error handling.
  
  ## Examples
  
      iex> HttpClient.get("https://api.example.com/data", [], timeout: 10_000)
      {:ok, %{"key" => "value"}}
  """
  @spec get(url(), headers(), opts()) :: http_result()
  def get(url, headers \\ [], opts \\ []) do
    request(:get, url, "", headers, opts)
  end

  @doc """
  Makes an HTTP POST request with standardized error handling.
  
  ## Examples
  
      iex> HttpClient.post("https://api.example.com/data", ~s({"key": "value"}), [], timeout: 10_000)
      {:ok, %{"result" => "ok"}}
  """
  @spec post(url(), String.t(), headers(), opts()) :: http_result()
  def post(url, body, headers \\ [], opts \\ []) do
    request(:post, url, body, headers, opts)
  end

  @doc """
  Makes an HTTP request with standardized error handling and JSON parsing.
  
  ## Options
  
    * `:timeout` - Request timeout in milliseconds (default: 15000)
    * `:recv_timeout` - Response timeout in milliseconds (default: 30000)
    * `:source` - Source name for error messages (default: "API")
    * `:expect_json` - Whether to parse response as JSON (default: true)
  """
  @spec request(method(), url(), String.t(), headers(), opts()) :: http_result()
  def request(method, url, body \\ "", headers \\ [], opts \\ []) do
    source = Keyword.get(opts, :source, "API")
    expect_json = Keyword.get(opts, :expect_json, true)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    recv_timeout = Keyword.get(opts, :recv_timeout, @default_recv_timeout)

    http_opts = [timeout: timeout, recv_timeout: recv_timeout]

    with {:ok, response} <- do_http_request(method, url, body, headers, http_opts, source),
         {:ok, parsed} <- parse_response(response, expect_json, source) do
      {:ok, parsed}
    end
  end

  @doc """
  Safely decodes JSON with standardized error handling.
  
  ## Examples
  
      iex> HttpClient.safe_decode(~s({"key": "value"}), "API")
      {:ok, %{"key" => "value"}}
      
      iex> HttpClient.safe_decode("invalid", "API")
      {:error, %{type: :parse_error, reason: "..."}}
  """
  @spec safe_decode(String.t(), String.t()) :: {:ok, term()} | Errors.error()
  def safe_decode(json, source \\ "API") do
    case Jason.decode(json) do
      {:ok, data} ->
        {:ok, data}

      {:error, %Jason.DecodeError{} = error} ->
        reason = "JSON decode error: #{Exception.message(error)}"
        log_error(source, reason)
        Errors.parse_error(reason)
    end
  end

  @doc """
  Adds an authorization header if the secret is configured.
  
  ## Examples
  
      iex> HttpClient.maybe_add_auth_header([], :api_key, "Bearer")
      [{"Authorization", "Bearer token123"}]
      
      iex> HttpClient.maybe_add_auth_header([], :missing_key, "Bearer")
      []
  """
  @spec maybe_add_auth_header(headers(), atom(), String.t()) :: headers()
  def maybe_add_auth_header(headers, secret_name, prefix \\ "Bearer") do
    case MarketIntel.Secrets.get(secret_name) do
      {:ok, key} -> [{"Authorization", "#{prefix} #{key}"} | headers]
      _ -> headers
    end
  end

  @doc """
  Schedules the next fetch for a GenServer.
  
  ## Examples
  
      iex> HttpClient.schedule_next_fetch(self(), :fetch, :timer.minutes(5))
      # Reference<...>
  """
  @spec schedule_next_fetch(pid(), atom(), non_neg_integer()) :: reference()
  def schedule_next_fetch(pid \\ self(), message, delay_ms) do
    Process.send_after(pid, message, delay_ms)
  end

  @doc """
  Logs an error with the standard MarketIntel prefix.
  
  ## Examples
  
      iex> HttpClient.log_error("Polymarket", "request failed")
      :ok
  """
  @spec log_error(String.t(), term()) :: :ok
  def log_error(source, reason) do
    Logger.warning("[MarketIntel] #{source}: #{format_reason(reason)}")
  end

  @doc """
  Logs an info message with the standard MarketIntel prefix.
  
  ## Examples
  
      iex> HttpClient.log_info("Polymarket", "fetching data")
      :ok
  """
  @spec log_info(String.t(), String.t()) :: :ok
  def log_info(source, message) do
    Logger.info("[MarketIntel] #{source}: #{message}")
  end

  # Private functions

  defp do_http_request(:get, url, _body, headers, opts, source) do
    case HTTPoison.get(url, headers, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %HTTPoison.Error{reason: reason}} ->
        error = Errors.network_error(reason)
        log_error(source, Errors.format_for_log(error))
        error
    end
  end

  defp do_http_request(:post, url, body, headers, opts, source) do
    case HTTPoison.post(url, body, headers, opts) do
      {:ok, response} ->
        {:ok, response}

      {:error, %HTTPoison.Error{reason: reason}} ->
        error = Errors.network_error(reason)
        log_error(source, Errors.format_for_log(error))
        error
    end
  end

  defp parse_response(%{status_code: 200, body: body}, true, source) do
    case safe_decode(body, source) do
      {:ok, data} -> {:ok, data}
      error -> error
    end
  end

  defp parse_response(%{status_code: 200, body: body}, false, _source) do
    {:ok, body}
  end

  defp parse_response(%{status_code: status, body: body}, _expect_json, source) do
    reason = "HTTP #{status}"
    log_error(source, "#{reason} - #{String.slice(body, 0, 200)}")
    Errors.api_error(source, reason)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end

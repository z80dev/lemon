defmodule MarketIntel.Secrets do
  @moduledoc """
  Secret resolution helper for MarketIntel.
  
  Uses LemonCore.Secrets store for secure API key storage.
  Falls back to environment variables if secrets store is not configured.
  
  ## Secret Names
  
  - `MARKET_INTEL_BASESCAN_KEY` - BaseScan API key
  - `MARKET_INTEL_DEXSCREENER_KEY` - DEX Screener API key (optional)
  - `MARKET_INTEL_OPENAI_KEY` - OpenAI API key for AI commentary
  - `MARKET_INTEL_ANTHROPIC_KEY` - Anthropic API key alternative
  
  ## Usage
  
      iex> MarketIntel.Secrets.get(:basescan_key)
      {:ok, "abc123"}
      
      iex> MarketIntel.Secrets.get!(:basescan_key)
      "abc123"
  """
  
  @secret_names %{
    basescan_key: "MARKET_INTEL_BASESCAN_KEY",
    dexscreener_key: "MARKET_INTEL_DEXSCREENER_KEY",
    openai_key: "MARKET_INTEL_OPENAI_KEY",
    anthropic_key: "MARKET_INTEL_ANTHROPIC_KEY",
    # X API keys (shared with lemon_channels)
    x_client_id: "X_API_CLIENT_ID",
    x_client_secret: "X_API_CLIENT_SECRET",
    x_access_token: "X_API_ACCESS_TOKEN",
    x_refresh_token: "X_API_REFRESH_TOKEN"
  }
  
  @doc """
  Get a secret by name.
  
  ## Examples
  
      iex> Secrets.get(:basescan_key)
      {:ok, "abc123"}
      
      iex> Secrets.get(:missing_key)
      {:error, :not_found}
  """
  @spec get(atom()) :: {:ok, String.t()} | {:error, atom()}
  def get(name) when is_atom(name) do
    secret_name = Map.get(@secret_names, name)
    
    if is_nil(secret_name) do
      {:error, :unknown_secret}
    else
      resolve_secret(secret_name)
    end
  end
  
  @doc """
  Get a secret by name, raising on error.
  """
  @spec get!(atom()) :: String.t()
  def get!(name) when is_atom(name) do
    case get(name) do
      {:ok, value} -> value
      {:error, reason} -> raise "Failed to get secret #{name}: #{reason}"
    end
  end
  
  @doc """
  Check if a secret is configured.
  """
  @spec configured?(atom()) :: boolean()
  def configured?(name) when is_atom(name) do
    case get(name) do
      {:ok, value} when is_binary(value) and value != "" -> true
      _ -> false
    end
  end
  
  @doc """
  Get all configured secrets for debugging.
  """
  @spec all_configured() :: %{atom() => String.t()}
  def all_configured do
    @secret_names
    |> Enum.map(fn {key, _} -> {key, get(key)} end)
    |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
    |> Enum.map(fn {key, {:ok, value}} -> {key, mask(value)} end)
    |> Enum.into(%{})
  end
  
  @doc """
  Store a secret in the secrets store.
  """
  @spec put(atom(), String.t()) :: :ok | {:error, term()}
  def put(name, value) when is_atom(name) and is_binary(value) do
    secret_name = Map.get(@secret_names, name)
    
    if is_nil(secret_name) do
      {:error, :unknown_secret}
    else
      do_persist(secret_name, value)
    end
  end
  
  # Private functions
  
  defp resolve_secret(name) do
    # Try secrets store first
    case resolve_from_secrets_store(name) do
      {:ok, value} -> {:ok, value}
      _ -> resolve_from_env(name)
    end
  end
  
  defp resolve_from_secrets_store(name) do
    if use_secrets_store?() do
      module = secrets_module()
      
      if is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, :resolve, 2) do
        case module.resolve(name, prefer_env: false, env_fallback: false) do
          {:ok, value, :store} -> {:ok, value}
          _ -> {:error, :not_in_store}
        end
      else
        {:error, :module_not_loaded}
      end
    else
      {:error, :secrets_disabled}
    end
  rescue
    _ -> {:error, :secrets_error}
  catch
    :exit, _ -> {:error, :secrets_exit}
  end
  
  defp resolve_from_env(name) do
    case System.get_env(name) do
      nil -> {:error, :not_in_env}
      "" -> {:error, :empty_in_env}
      value -> {:ok, value}
    end
  end
  
  defp do_persist(name, value) do
    if use_secrets_store?() do
      module = secrets_module()
      
      if is_atom(module) and Code.ensure_loaded?(module) and
           function_exported?(module, :persist, 2) do
        module.persist(name, value)
      else
        {:error, :persist_module_not_loaded}
      end
    else
      {:error, :secrets_disabled}
    end
  end
  
  defp use_secrets_store? do
    Application.get_env(:market_intel, :use_secrets, true) != false
  end
  
  defp secrets_module do
    Application.get_env(:market_intel, :secrets_module, LemonCore.Secrets)
  end
  
  defp mask(value) when is_binary(value) do
    len = String.length(value)
    
    if len <= 8 do
      "***"
    else
      prefix = String.slice(value, 0, 4)
      suffix = String.slice(value, -4, 4)
      "#{prefix}...#{suffix}"
    end
  end
end

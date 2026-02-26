defmodule Ai.ProviderRegistry do
  @moduledoc """
  Registry for LLM provider implementations.

  Providers are registered by their API identifier and can be looked up
  at runtime. This module uses `:persistent_term` for crash-resilient
  storage - the registry survives process restarts without re-registration.

  ## Design

  Unlike a GenServer-based registry, this implementation stores provider
  mappings in `:persistent_term`, which:
  - Survives process crashes and restarts
  - Provides O(1) read access with no message passing
  - Is optimized for read-heavy, write-rarely patterns (perfect for registries)

  ## Usage

      # Registration (typically during application startup)
      Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)

      # Lookup (fast, no GenServer call)
      {:ok, module} = Ai.ProviderRegistry.get(:anthropic_messages)
  """

  @persistent_term_key {__MODULE__, :providers}
  @mutation_lock {__MODULE__, :mutation_lock}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Initialize the registry with default providers.

  Called during application startup. Safe to call multiple times.
  """
  @spec init() :: :ok
  def init do
    with_mutation_lock(fn ->
      # Only initialize if not already set
      unless initialized?() do
        :persistent_term.put(@persistent_term_key, %{})
      end

      :ok
    end)
  end

  @doc """
  Register a provider module for an API.

  This is a write operation that updates `:persistent_term`. While safe,
  it should be called sparingly (ideally only during application startup)
  as `:persistent_term` writes trigger a global GC of the term.
  """
  @spec register(atom(), module()) :: :ok
  def register(api_id, module) when is_atom(api_id) and is_atom(module) do
    mutate_providers(fn providers ->
      Map.put(providers, api_id, module)
    end)
  end

  @doc """
  Get the provider module for an API.

  This is a fast O(1) read operation with no message passing.
  """
  @spec get(atom()) :: {:ok, module()} | {:error, :not_found}
  def get(api_id) when is_atom(api_id) do
    ensure_initialized()
    providers = :persistent_term.get(@persistent_term_key)

    case Map.fetch(providers, api_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Get the provider module for an API, raising if not found.
  """
  @spec get!(atom()) :: module()
  def get!(api_id) when is_atom(api_id) do
    case get(api_id) do
      {:ok, module} -> module
      {:error, :not_found} -> raise ArgumentError, "Provider not found for API: #{api_id}"
    end
  end

  @doc """
  List all registered API identifiers.
  """
  @spec list() :: [atom()]
  def list do
    ensure_initialized()
    providers = :persistent_term.get(@persistent_term_key)
    Map.keys(providers)
  end

  @doc """
  Check if a provider is registered for an API.
  """
  @spec registered?(atom()) :: boolean()
  def registered?(api_id) when is_atom(api_id) do
    ensure_initialized()
    providers = :persistent_term.get(@persistent_term_key)
    Map.has_key?(providers, api_id)
  end

  @doc """
  Unregister a provider. Primarily useful for testing.
  """
  @spec unregister(atom()) :: :ok
  def unregister(api_id) when is_atom(api_id) do
    mutate_providers(fn providers ->
      Map.delete(providers, api_id)
    end)
  end

  @doc """
  Clear all providers. Primarily useful for testing.
  """
  @spec clear() :: :ok
  def clear do
    mutate_providers(fn _providers -> %{} end)
  end

  @doc """
  Check if the registry has been initialized.
  """
  @spec initialized?() :: boolean()
  def initialized? do
    try do
      :persistent_term.get(@persistent_term_key)
      true
    rescue
      ArgumentError -> false
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp ensure_initialized do
    unless initialized?() do
      init()
    end
  end

  defp mutate_providers(update_fun) do
    with_mutation_lock(fn ->
      providers =
        if initialized?() do
          :persistent_term.get(@persistent_term_key)
        else
          %{}
        end

      :persistent_term.put(@persistent_term_key, update_fun.(providers))
      :ok
    end)
  end

  defp with_mutation_lock(fun) do
    :global.trans({@mutation_lock, self()}, fun)
  end
end

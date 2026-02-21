defmodule Ai.Application do
  @moduledoc """
  OTP Application for the AI module.

  ## Supervision Tree

  - `Ai.Supervisor` (one_for_one)
    - `Ai.StreamTaskSupervisor` - Dynamic supervisor for streaming tasks
    - `Ai.RateLimiterRegistry` - Registry for per-provider rate limiters
    - `Ai.CircuitBreakerRegistry` - Registry for per-provider circuit breakers
    - `Ai.CallDispatcher` - Central dispatcher for request coordination
    - `Ai.ProviderSupervisor` - Dynamic supervisor for per-provider services

  ## Design Decisions

  - **ProviderRegistry**: Uses `:persistent_term` instead of a GenServer for
    crash resilience. Providers survive process restarts without re-registration.

  - **StreamTaskSupervisor**: A `Task.Supervisor` that manages all provider
    streaming tasks. This ensures proper lifecycle management and crash isolation.

  - **Rate Limiting & Circuit Breaking**: Per-provider GenServers registered
    via `Ai.RateLimiterRegistry` and `Ai.CircuitBreakerRegistry`. Started
    on-demand when providers are first used.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize provider registry (uses :persistent_term, not a process)
    Ai.ProviderRegistry.init()

    children = [
      # Task supervisor for streaming operations
      {Task.Supervisor, name: Ai.StreamTaskSupervisor},
      # Registry for per-provider rate limiters
      {Registry, keys: :unique, name: Ai.RateLimiterRegistry},
      # Registry for per-provider circuit breakers
      {Registry, keys: :unique, name: Ai.CircuitBreakerRegistry},
      # Dynamic supervisor for per-provider services
      Ai.ProviderSupervisor,
      # Central call dispatcher
      {Ai.CallDispatcher, []},
      # Model availability cache (ETS-backed)
      Ai.ModelCache
    ]

    opts = [strategy: :one_for_one, name: Ai.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Register providers after initialization
    register_providers()

    result
  end

  @doc """
  Register all built-in providers.

  This is called during application startup and can also be called
  to re-register providers if needed.
  """
  def register_providers do
    # Anthropic
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)

    # OpenAI family
    Ai.ProviderRegistry.register(:openai_completions, Ai.Providers.OpenAICompletions)
    Ai.ProviderRegistry.register(:openai_responses, Ai.Providers.OpenAIResponses)
    Ai.ProviderRegistry.register(:openai_codex_responses, Ai.Providers.OpenAICodexResponses)
    Ai.ProviderRegistry.register(:azure_openai_responses, Ai.Providers.AzureOpenAIResponses)

    # Google family
    Ai.ProviderRegistry.register(:google_generative_ai, Ai.Providers.Google)
    Ai.ProviderRegistry.register(:google_vertex, Ai.Providers.GoogleVertex)
    Ai.ProviderRegistry.register(:google_gemini_cli, Ai.Providers.GoogleGeminiCli)

    # AWS
    Ai.ProviderRegistry.register(:bedrock_converse_stream, Ai.Providers.Bedrock)

    :ok
  end
end

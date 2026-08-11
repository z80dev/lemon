defmodule LemonAi.Application do
  @moduledoc """
  OTP Application for the AI module.

  ## Supervision Tree

  - `LemonAi.Supervisor` (one_for_one)
    - `LemonAi.StreamTaskSupervisor` - Dynamic supervisor for streaming tasks
    - `LemonAi.RateLimiterRegistry` - Registry for per-provider rate limiters
    - `LemonAi.CircuitBreakerRegistry` - Registry for per-provider circuit breakers
    - `LemonAi.CallDispatcher` - Central dispatcher for request coordination
    - `LemonAi.ProviderSupervisor` - Dynamic supervisor for per-provider services

  ## Design Decisions

  - **ProviderRegistry**: Uses `:persistent_term` instead of a GenServer for
    crash resilience. Providers survive process restarts without re-registration.

  - **StreamTaskSupervisor**: A `Task.Supervisor` that manages all provider
    streaming tasks. This ensures proper lifecycle management and crash isolation.

  - **Rate Limiting & Circuit Breaking**: Per-provider GenServers registered
    via `LemonAi.RateLimiterRegistry` and `LemonAi.CircuitBreakerRegistry`. Started
    on-demand when providers are first used.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize provider registry (uses :persistent_term, not a process)
    LemonAi.ProviderRegistry.init()

    children = [
      # Task supervisor for streaming operations
      {Task.Supervisor, name: LemonAi.StreamTaskSupervisor},
      # Registry for per-provider rate limiters
      {Registry, keys: :unique, name: LemonAi.RateLimiterRegistry},
      # Registry for per-provider circuit breakers
      {Registry, keys: :unique, name: LemonAi.CircuitBreakerRegistry},
      # Dynamic supervisor for per-provider services
      LemonAi.ProviderSupervisor,
      # Central call dispatcher
      {LemonAi.CallDispatcher, []},
      # Model availability cache (ETS-backed)
      LemonAi.ModelCache
    ]

    opts = [strategy: :one_for_one, name: LemonAi.Supervisor]
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
    LemonAi.ProviderRegistry.register(:anthropic_messages, LemonAi.Providers.Anthropic)

    # OpenAI family
    LemonAi.ProviderRegistry.register(:openai_completions, LemonAi.Providers.OpenAICompletions)
    LemonAi.ProviderRegistry.register(:openai_responses, LemonAi.Providers.OpenAIResponses)

    LemonAi.ProviderRegistry.register(
      :openai_codex_responses,
      LemonAi.Providers.OpenAICodexResponses
    )

    LemonAi.ProviderRegistry.register(
      :azure_openai_responses,
      LemonAi.Providers.AzureOpenAIResponses
    )

    # Google family
    LemonAi.ProviderRegistry.register(:google_generative_ai, LemonAi.Providers.Google)
    LemonAi.ProviderRegistry.register(:google_vertex, LemonAi.Providers.GoogleVertex)
    LemonAi.ProviderRegistry.register(:google_gemini_cli, LemonAi.Providers.GoogleGeminiCli)

    # AWS
    LemonAi.ProviderRegistry.register(:bedrock_converse_stream, LemonAi.Providers.Bedrock)

    # Mistral
    LemonAi.ProviderRegistry.register(
      :mistral_conversations,
      LemonAi.Providers.MistralConversations
    )

    :ok
  end
end

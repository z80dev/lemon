defmodule LemonAi.ProviderSupervisor do
  @moduledoc """
  `DynamicSupervisor` for per-provider services.

  Rate limiters (`LemonAi.RateLimiter`) and circuit breakers (`LemonAi.CircuitBreaker`) are
  started as children here on demand, one set per provider, so a misbehaving
  provider's limiter or breaker can restart without affecting the others.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

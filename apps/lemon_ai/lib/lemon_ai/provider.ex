defmodule LemonAi.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Each provider (Anthropic, OpenAI, Google, etc.) implements this behaviour
  to provide a unified streaming interface.

  ## Implementing a Provider

      defmodule LemonAi.Providers.Anthropic do
        @behaviour LemonAi.Provider

        @impl true
        def stream(model, context, opts) do
          # Implementation...
        end
      end
  """

  alias LemonAi.Types.{Context, Model, StreamOptions}
  alias LemonAi.EventStream

  @doc """
  Start streaming a response from the provider.

  Returns an EventStream that emits events as the response is generated.
  The caller should consume events using `EventStream.events/1` or
  wait for the final result with `EventStream.result/1`.
  """
  @callback stream(Model.t(), Context.t(), StreamOptions.t()) ::
              {:ok, EventStream.t()} | {:error, term()}

  @doc """
  Get the API key from environment variables for this provider.
  """
  @callback get_env_api_key() :: String.t() | nil

  @doc """
  Provider identifier atom.
  """
  @callback provider_id() :: atom()

  @doc """
  API identifier atom.
  """
  @callback api_id() :: atom()

  @doc """
  Builds the bounded provider retry policy from application defaults and request overrides.

  `StreamOptions.provider_retry` overrides `:lemon_ai, :provider_retry`. Timing
  and budgets belong to `LemonAi.Retry`; provider classification stays here.
  Default waits use the notification-aware deadline in `LemonAi.Retry`.
  A request-local `sleep_fun: nil` restores that wait when application defaults
  inject a custom sleeper.
  """
  def retry_policy(options \\ nil) do
    configured = :lemon_ai |> Application.get_env(:provider_retry, []) |> Map.new()

    provider_defaults = %{
      max_attempts: 4,
      base_delay_ms: 1_000,
      max_delay_ms: 30_000,
      max_retry_after_ms: 60_000
    }

    configured_values =
      Enum.reduce(provider_defaults, %{}, fn {key, default}, acc ->
        value = Map.get(configured, key)
        Map.put(acc, key, if(is_integer(value) and value > 0, do: value, else: default))
      end)
      |> Map.put(:sleep_fun, Map.get(configured, :sleep_fun))
      |> Map.put(:jitter_fun, Map.get(configured, :jitter_fun, &:rand.uniform/1))

    defaults = LemonAi.Retry.policy(configured_values)

    overrides =
      case options do
        %{provider_retry: overrides} when is_map(overrides) -> overrides
        _ -> %{}
      end

    numeric = [:max_attempts, :base_delay_ms, :max_delay_ms, :max_retry_after_ms]

    values =
      Enum.reduce(numeric, Map.from_struct(defaults), fn key, acc ->
        case Map.get(overrides, key) do
          value when is_integer(value) and value > 0 -> Map.put(acc, key, value)
          _ -> acc
        end
      end)
      |> Map.merge(Map.take(overrides, [:jitter_fun, :sleep_fun]))
      |> Map.put(:alternate_available, Map.get(overrides, :alternate_available) == true)
      |> Map.put(:classify, &LemonAi.Error.classify/1)
      |> Map.put(:error_retry_after_ms, &LemonAi.Error.retry_after_ms/1)

    LemonAi.Retry.policy(values)
  end

  @doc "Waits using the provider policy's default deadline or injectable sleep callback."
  def retry_sleep(ms, policy \\ retry_policy()) do
    _ = LemonAi.Retry.wait(ms, sleep_fun: policy.sleep_fun)
    :ok
  end

  @optional_callbacks [get_env_api_key: 0]
end

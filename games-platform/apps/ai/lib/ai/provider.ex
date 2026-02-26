defmodule Ai.Provider do
  @moduledoc """
  Behaviour for LLM provider implementations.

  Each provider (Anthropic, OpenAI, Google, etc.) implements this behaviour
  to provide a unified streaming interface.

  ## Implementing a Provider

      defmodule Ai.Providers.Anthropic do
        @behaviour Ai.Provider

        @impl true
        def stream(model, context, opts) do
          # Implementation...
        end
      end
  """

  alias Ai.Types.{Context, Model, StreamOptions}
  alias Ai.EventStream

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

  @optional_callbacks [get_env_api_key: 0]
end

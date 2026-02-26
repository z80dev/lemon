defmodule LemonGateway.Transport do
  @moduledoc """
  Behaviour for transport plugins that receive messages from external sources.

  A transport is responsible for:
  - Connecting to an external messaging service (Telegram, Discord, etc.)
  - Converting incoming messages to Jobs
  - Submitting jobs to the gateway

  ## Usage

      defmodule MyTransport do
        use LemonGateway.Transport

        @impl true
        def id, do: "mytransport"

        @impl true
        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: __MODULE__)
        end
      end
  """

  @doc """
  Returns the unique identifier for this transport.

  Must be a lowercase string matching `^[a-z][a-z0-9_-]*$`.
  """
  @callback id() :: String.t()

  @doc """
  Starts the transport process.

  The transport should start any required polling or connection management.
  Returns `{:ok, pid}` on success, `:ignore` if the transport is disabled,
  or `{:error, reason}` on failure.
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  @doc """
  Returns the child spec for starting this transport under a supervisor.

  Optional callback - defaults to a worker spec using `start_link/1`.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @optional_callbacks child_spec: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonGateway.Transport

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 5000
        }
      end

      defoverridable child_spec: 1
    end
  end
end

defmodule LemonCore.RouterBridge.Router do
  @moduledoc """
  The router half of `LemonCore.RouterBridge`: what a message router must
  implement to be registered under the `:router` key.

  `LemonCore.RouterBridge.configure/1` validates the module against this
  behaviour with `LemonCore.Contract.validate/2`, so once a router is
  registered the bridge calls it directly.

  ## Defaults for partial routers

  `use LemonCore.RouterBridge.Router` injects an overridable implementation of
  every callback that raises `LemonCore.RouterBridge.NotImplementedError`. A
  partial router, typically a test double, therefore satisfies the contract
  while any call it does not handle is reported by the bridge as
  `{:error, %LemonCore.RouterBridge.NotImplementedError{}}` rather than
  answered with an invented value.
  """

  alias LemonCore.InboundMessage

  @doc "Route an inbound channel message."
  @callback handle_inbound(InboundMessage.t()) :: :ok | {:error, term()}

  @doc "Abort every run of a session. Total and idempotent: unknown sessions are `:ok`."
  @callback abort(session_key :: binary(), reason :: term()) :: :ok

  @doc "Abort one run by id. Total and idempotent: finished or unknown runs are `:ok`."
  @callback abort_run(run_id :: binary(), reason :: term()) :: :ok

  @doc "Apply a watchdog keep-alive decision to a run. Unknown runs are `:ok`."
  @callback keep_run_alive(run_id :: binary(), decision :: :continue | :cancel) :: :ok

  @doc "Whether the session currently has an active run."
  @callback session_busy?(session_key :: binary()) :: boolean()

  @doc "The active run of a session, if any."
  @callback active_run(session_key :: binary()) :: {:ok, binary()} | :none

  @doc "Every session with an active run."
  @callback list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]

  defmacro __using__(_opts) do
    quote do
      @behaviour LemonCore.RouterBridge.Router

      alias LemonCore.RouterBridge.NotImplementedError

      def handle_inbound(_message),
        do: raise(NotImplementedError, module: __MODULE__, function: :handle_inbound, arity: 1)

      def abort(_session_key, _reason),
        do: raise(NotImplementedError, module: __MODULE__, function: :abort, arity: 2)

      def abort_run(_run_id, _reason),
        do: raise(NotImplementedError, module: __MODULE__, function: :abort_run, arity: 2)

      def keep_run_alive(_run_id, _decision),
        do: raise(NotImplementedError, module: __MODULE__, function: :keep_run_alive, arity: 2)

      def session_busy?(_session_key),
        do: raise(NotImplementedError, module: __MODULE__, function: :session_busy?, arity: 1)

      def active_run(_session_key),
        do: raise(NotImplementedError, module: __MODULE__, function: :active_run, arity: 1)

      def list_active_sessions,
        do:
          raise(NotImplementedError,
            module: __MODULE__,
            function: :list_active_sessions,
            arity: 0
          )

      defoverridable LemonCore.RouterBridge.Router
    end
  end
end

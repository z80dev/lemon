defmodule LemonBrowser.SessionProvider do
  @moduledoc """
  Lifecycle contract for hosted browser providers that expose a CDP endpoint.

  Provider sessions are transport only. Lemon keeps navigation policy, typed
  actions, artifacts, approvals, and result redaction above this boundary.
  """

  @type session :: %{
          required(:id) => String.t(),
          required(:cdp_endpoint) => String.t(),
          optional(:expires_at) => String.t() | nil,
          optional(:features) => map()
        }

  @callback id() :: atom()
  @callback available?() :: boolean()
  @callback available?(keyword()) :: boolean()
  @callback create_session(String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback close_session(String.t(), keyword()) :: :ok | {:error, term()}
  @callback status() :: map()

  @optional_callbacks available?: 1
end

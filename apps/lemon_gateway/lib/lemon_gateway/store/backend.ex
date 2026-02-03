defmodule LemonGateway.Store.Backend do
  @moduledoc """
  Behaviour for pluggable storage backends.

  A backend provides key-value storage across multiple logical tables.
  """

  @type state :: term()
  @type table :: atom()
  @type key :: term()
  @type value :: term()
  @type opts :: keyword()

  @doc """
  Initialize the backend with the given options.
  Returns `{:ok, state}` or `{:error, reason}`.
  """
  @callback init(opts()) :: {:ok, state()} | {:error, term()}

  @doc """
  Store a value under the given table and key.
  """
  @callback put(state(), table(), key(), value()) :: {:ok, state()}

  @doc """
  Retrieve a value by table and key.
  Returns `{:ok, value, state}` where value is `nil` if not found.
  """
  @callback get(state(), table(), key()) :: {:ok, value() | nil, state()}

  @doc """
  Delete a value by table and key.
  """
  @callback delete(state(), table(), key()) :: {:ok, state()}

  @doc """
  List all key-value pairs in a table.
  Returns `{:ok, [{key, value}], state}`.
  """
  @callback list(state(), table()) :: {:ok, [{key(), value()}], state()}
end

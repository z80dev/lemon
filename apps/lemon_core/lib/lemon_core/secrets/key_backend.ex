defmodule LemonCore.Secrets.KeyBackend do
  @moduledoc """
  Behaviour for master key storage backends.

  Each backend must implement four callbacks that manage a single
  master-key entry.  The `available?/0` callback lets `MasterKey`
  skip backends that cannot function on the current platform.
  """

  @callback available?() :: boolean()
  @callback get_master_key(keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback put_master_key(String.t(), keyword()) :: :ok | {:error, term()}
  @callback delete_master_key(keyword()) :: :ok | {:error, term()}
end

defmodule LemonCore.Service.Manager do
  @moduledoc false
  @callback available?(keyword()) :: boolean()
  @callback install(map(), keyword()) :: :ok | {:error, atom()}
  @callback status(map(), keyword()) :: map()
  @callback start(map(), keyword()) :: :ok | {:error, atom()}
  @callback restart(map(), keyword()) :: :ok | {:error, atom()}
  @callback stop(map(), keyword()) :: :ok | {:error, atom()}
  @callback uninstall(map(), keyword()) :: :ok | {:error, atom()}
  @callback persistence(keyword()) :: {String.t(), boolean() | nil}
end

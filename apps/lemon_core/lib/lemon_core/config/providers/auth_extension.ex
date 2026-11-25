defmodule LemonCore.Config.Providers.AuthExtension do
  @moduledoc """
  Optional provider-runtime authentication configuration. The product registers
  its implementation under `config :lemon_core, :provider_auth_extension`.
  Core handles the ordinary API key and OAuth fields without an extension.
  """

  @callback settings(map()) :: map()
  @callback sources(String.t()) :: [String.t()]
  @callback source?(term()) :: boolean()
  @callback public_provider?(String.t()) :: boolean()
  @callback external?(term(), map()) :: boolean()
  @callback validate([String.t()], term(), map(), String.t()) :: [String.t()]
  @callback credential_check(term(), map(), boolean()) :: LemonCore.Doctor.Check.t() | nil

  @doc false
  def call(operation, args, default) do
    case Application.get_env(:lemon_core, :provider_auth_extension) do
      nil -> default
      extension -> apply(extension, operation, args)
    end
  end
end

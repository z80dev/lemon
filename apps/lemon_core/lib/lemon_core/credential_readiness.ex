defmodule LemonCore.CredentialReadiness do
  @moduledoc """
  Core entry point to the model runtime's single credential-readiness predicate.

  Core diagnostics (`lemon doctor`, first-run setup readiness, support bundles)
  must answer "does this provider have a usable credential?" exactly as the
  runtime, provider status and CLI do, but core cannot depend on the runtime.
  The reference runtime registers the implementation as a doctor runtime module:

      config :lemon_core, :doctor_runtime,
        credential_readiness: LemonAgent.ModelRuntime.Credentials

  The module exports `credential_readiness(provider, providers, opts)`, called
  here in its side-effect-free presence mode: it never decrypts a value,
  refreshes an OAuth login, runs an external credential command, or makes a
  network request. Without a registered implementation every provider is
  `:unavailable` (not ready).
  """

  alias LemonCore.Doctor.RuntimeModules

  @type status :: :ready | :not_required | :missing | :unusable | :unavailable

  @doc """
  Credential status for `provider` under the `providers` table.

  ## Options

    * `:provider_routing` - routing config whose credential pools also count
    * `:cwd` - project directory for project-scoped settings
  """
  @spec status(term(), map() | nil, keyword()) :: status()
  def status(provider, providers, opts \\ [])

  def status(provider, providers, opts) when is_binary(provider) or is_atom(provider) do
    case implementation() do
      nil ->
        :unavailable

      mod ->
        case mod.credential_readiness(
               provider,
               providers || %{},
               Keyword.put(opts, :mode, :presence)
             ) do
          status when status in [:ready, :not_required, :missing, :unusable] -> status
          _ -> :unavailable
        end
    end
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
  end

  def status(_provider, _providers, _opts), do: :missing

  @doc "Whether `status/3` reports a usable (or unneeded) credential."
  @spec ready?(term(), map() | nil, keyword()) :: boolean()
  def ready?(provider, providers, opts \\ []),
    do: status(provider, providers, opts) in [:ready, :not_required]

  defp implementation do
    mod = RuntimeModules.fetch(:credential_readiness)

    if mod != nil and Code.ensure_loaded?(mod) and
         function_exported?(mod, :credential_readiness, 3),
       do: mod
  end
end

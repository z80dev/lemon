defmodule LemonCore.Doctor.RuntimeModules do
  @moduledoc """
  Config-injected module references for diagnostics owned by other apps.

  The doctor framework lives in lemon_core, but several of the things it
  reports on — media jobs, browser artifacts, language servers — are owned by
  apps that lemon_core must not depend on. Rather than naming those modules
  directly, the framework looks them up here and the reference runtime injects
  them:

      config :lemon_core, :doctor_runtime,
        media_jobs: MyApp.MediaJobs,
        lsp_server_manager: MyApp.ServerManager

  The umbrella's own registrations live in `config/config.exs`.

  This is the same pattern as `:workspace_diagnostics`. An unconfigured key
  returns `nil`, which callers treat as "that runtime is not available" — the
  diagnostics degrade to their documented fallbacks instead of failing.
  """

  @type key :: atom()

  @doc "Returns the module registered under `key`, or `nil`."
  @spec fetch(key()) :: module() | nil
  def fetch(key) when is_atom(key) do
    :lemon_core
    |> Application.get_env(:doctor_runtime, [])
    |> Keyword.get(key)
  end

  @doc "All registered runtime modules, for introspection."
  @spec all() :: keyword()
  def all, do: Application.get_env(:lemon_core, :doctor_runtime, [])
end

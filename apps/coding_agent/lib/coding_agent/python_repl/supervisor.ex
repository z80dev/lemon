defmodule CodingAgent.PythonRepl.Supervisor do
  @moduledoc """
  `:one_for_all` supervisor anchoring the persistent Python REPL subsystem.

  Children, in start order:

    * `CodingAgent.PythonRepl.SessionSupervisor` - the `DynamicSupervisor`
      that owns the temporary `CodingAgent.PythonRepl.Session` workers.
    * `CodingAgent.PythonRepl.Registry` - the GenServer owning key/owner
      mappings, generations, admission, and reaping; it starts workers
      through the sibling session supervisor.

  `:one_for_all` is deliberate: the registry is the only record of which
  worker belongs to which key, owner, and generation, so its crash must
  tear down every interpreter rather than leave orphaned workers whose
  ownership can no longer be decided. Both children then restart together
  into a fresh, empty subsystem. Session workers are
  `restart: :temporary`, so this teardown leaves nothing behind and any
  replacement is registry-driven through a new generation.

  `CodingAgent.Application` must start this module strictly after
  `CodingAgent.TaskSupervisor` exists, because the per-cell RPC servers
  later started for workers depend on that supervisor.

  ## Options

    * `:name` - supervisor name (default `__MODULE__`).
    * `:session_supervisor_mod` / `:registry_mod` - injectable child
      modules, so supervision tests can run isolated trees with stand-ins
      (mirroring the injectable-mod convention of `PythonRepl.Session`).
      Defaults are the real modules above.
    * `:session_supervisor_opts` / `:registry_opts` - pass-through child
      start opts. Each child's `name:` defaults to its module, and the
      registry's `session_supervisor:` defaults to the sibling
      supervisor's resolved name so a custom-named tree stays coherent.
  """

  use Supervisor

  @default_session_supervisor_mod CodingAgent.PythonRepl.SessionSupervisor
  @default_registry_mod CodingAgent.PythonRepl.Registry

  @type option ::
          {:name, Supervisor.name()}
          | {:session_supervisor_mod, module()}
          | {:registry_mod, module()}
          | {:session_supervisor_opts, keyword()}
          | {:registry_opts, keyword()}

  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    session_supervisor_mod =
      Keyword.get(opts, :session_supervisor_mod, @default_session_supervisor_mod)

    registry_mod = Keyword.get(opts, :registry_mod, @default_registry_mod)

    session_supervisor_opts =
      opts
      |> Keyword.get(:session_supervisor_opts, [])
      |> Keyword.put_new(:name, session_supervisor_mod)

    registry_opts =
      opts
      |> Keyword.get(:registry_opts, [])
      |> Keyword.put_new(:name, registry_mod)
      |> Keyword.put_new(:session_supervisor, session_supervisor_opts[:name])

    children = [
      {session_supervisor_mod, session_supervisor_opts},
      {registry_mod, registry_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end

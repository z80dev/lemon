defmodule LemonMemory.Application do
  @moduledoc """
  Supervision tree for durable agent memory.

  Starts the provider registry unconditionally — it is a routing boundary and
  useful even with no local store — and the SQLite-backed store plus its ingest
  pipeline when the SQLite NIF is loadable.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [LemonMemory.Providers] ++ sqlite_children()

    opts = [strategy: :one_for_one, name: LemonMemory.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # `:exqlite` is a direct dependency here, so this is a guard rather than a
  # switch: it keeps the app booting (with durable memory disabled) in stripped
  # builds where the NIF failed to load, matching how lemon_core treats its own
  # optional SQLite subsystems.
  defp sqlite_children do
    if Code.ensure_loaded?(Exqlite.Sqlite3) do
      [LemonMemory.Store, LemonMemory.Ingest]
    else
      Logger.info(
        "exqlite is not available: durable memory is disabled. " <>
          "Add {:exqlite, \"~> 0.34\"} to your deps to enable it."
      )

      []
    end
  end
end

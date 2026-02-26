defmodule LemonServices.Supervisor do
  @moduledoc """
  Top-level supervisor for LemonServices.

  Manages:
  - LogBuffer ETS table owner
  - Config loader for static service definitions
  - Service definition store
  """
  use Supervisor

  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # ETS table owner for log buffers
      LemonServices.Runtime.LogBuffer.TableOwner,

      # Service definition store (ETS-backed)
      LemonServices.Service.Store,

      # Config loader - loads static services from YAML
      LemonServices.Config.Loader
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

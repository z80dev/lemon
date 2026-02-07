defmodule LemonCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config_cache_opts = Application.get_env(:lemon_core, LemonCore.ConfigCache, [])

    children = [
      {Phoenix.PubSub, name: LemonCore.PubSub},
      {LemonCore.ConfigCache, config_cache_opts},
      LemonCore.Store
    ]

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

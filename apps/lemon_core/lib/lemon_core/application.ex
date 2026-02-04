defmodule LemonCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LemonCore.PubSub}
    ]

    opts = [strategy: :one_for_one, name: LemonCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

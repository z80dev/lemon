defmodule LemonBrowser.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LemonBrowser.LocalServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonBrowser.Supervisor)
  end
end

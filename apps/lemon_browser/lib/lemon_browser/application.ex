defmodule LemonBrowser.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Started before the session supervisors so it outlives their cleanup.
      LemonBrowser.CredentialVault,
      {Registry, keys: :unique, name: LemonBrowser.CloudSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonBrowser.CloudSessionSupervisor},
      {Registry, keys: :unique, name: LemonBrowser.CamofoxSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonBrowser.CamofoxSessionSupervisor},
      {Registry, keys: :unique, name: LemonBrowser.TernSessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: LemonBrowser.TernSessionSupervisor},
      LemonBrowser.LocalServer
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LemonBrowser.Supervisor)
  end
end

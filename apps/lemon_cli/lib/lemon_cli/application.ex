defmodule LemonCli.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    :ok = LemonCore.ProviderManagement.register(LemonCli.Setup.ProviderManagement)

    Supervisor.start_link(
      [LemonCli.Setup.DeviceLogin],
      strategy: :one_for_one,
      name: LemonCli.Supervisor
    )
  end
end

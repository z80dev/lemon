defmodule LemonSim.Application do
  @moduledoc """
  OTP application for LemonSim.

  Phase 0 is contract-first and does not require background workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: LemonSim.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

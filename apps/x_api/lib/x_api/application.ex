defmodule XApi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:x_api, :start_token_manager, true) != false do
        [XApi.TokenManager]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: XApi.Supervisor)
  end
end
